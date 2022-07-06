{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module S3Up.DB (
  HasS3UpDB(..),
  withDB,
  initTables,
  storeUpload,
  completedUploadPart,
  completedUpload,
  abortedUpload,
  listPartialUploads,
  listQueuedFiles) where

import           Amazonka                         (FromText, ToByteString (..), ToText (..), fromText)
import           Amazonka.S3.Types                (BucketName (..), ETag (..), ObjectKey (..))
import           Control.Monad.IO.Class           (MonadIO (..))
import           Control.Monad.Reader             (ReaderT (..), ask, runReaderT)
import qualified Data.ByteString                  as BS
import           Data.List                        (sortOn)
import qualified Data.Map.Strict                  as Map
import           Data.Maybe                       (isNothing)
import           Data.String                      (fromString)
import qualified Data.Text                        as T
import           Data.Typeable                    (Typeable)
import           Database.SQLite.Simple           hiding (bind, close)
import           Database.SQLite.Simple.FromField
import           Database.SQLite.Simple.Ok
import           Database.SQLite.Simple.ToField
import           Text.Read                        (readMaybe)

import           S3Up.Types

class Monad m => HasS3UpDB m where
  s3UpDB :: m Connection

instance {-# OVERLAPPING #-} Monad m => HasS3UpDB (ReaderT Connection m) where s3UpDB = ask

withDB :: Connection -> ReaderT Connection m a -> m a
withDB = flip runReaderT

instance FromRow PartialUpload where
  fromRow =
    PartialUpload <$> field -- id
    <*> field -- chunkSize
    <*> field -- bucket
    <*> field -- filename
    <*> field -- key
    <*> field -- upid
    <*> field -- hook
    <*> pure []

textField :: (Typeable a, FromText a) => Field -> Ok a
textField f = case fieldData f of
                (SQLText t) -> either (returnError ConversionFailed f) Ok (fromText t)
                _           -> returnError ConversionFailed f "invalid type"

blobField :: Typeable a => (BS.ByteString -> a) -> Field -> Ok a
blobField c f = case fieldData f of
                  (SQLBlob b) -> Ok (c b)
                  _           -> returnError ConversionFailed f "invalid type"

instance ToField ObjectKey where toField = toField . toText
instance FromField ObjectKey where fromField = textField

instance ToField BucketName where toField = toField . toText
instance FromField BucketName where fromField = textField

instance ToField ETag where toField = toField . toBS
instance FromField ETag where fromField = blobField ETag

instance ToField PostUploadHook where toField = toField . show

instance FromField PostUploadHook where
  fromField f = case fieldData f of
                  (SQLText t) -> maybe (returnError ConversionFailed f ("could not parse " <> show t)) Ok (readMaybe (T.unpack t))
                  _ -> returnError ConversionFailed f "invalid type"

initQueries :: [(Int, Query)]
initQueries = [
  (1, "create table if not exists uploads (id integer primary key autoincrement, chunk_size, bucket_name, filename, key, upid)"),
  (1, "create table if not exists upload_parts (id integer, part integer, etag)"),
  (2, "alter table uploads add column post_upload string")
  ]

initTables :: Connection -> IO ()
initTables db = do
  [Only uv] <- query_ db "pragma user_version"
  mapM_ (execute_ db) [q | (v,q) <- initQueries, v > uv]
  -- binding doesn't work on this for some reason.  It's safe, at least.
  execute_ db $ "pragma user_version = " <> (fromString . show . maximum . fmap fst $ initQueries)

-- A simple query.
q_ :: (HasS3UpDB m, MonadIO m, FromRow r) => Query -> m [r]
q_ q = liftIO . flip query_ q =<< s3UpDB

-- execute many
em :: (HasS3UpDB m, MonadIO m, ToRow r) => Query -> [r] -> m ()
em q rs = s3UpDB >>= \db -> liftIO $ executeMany db q rs

-- execute
ex :: (HasS3UpDB m, MonadIO m, ToRow r) => Query -> r -> m ()
ex q r = s3UpDB >>= \db -> liftIO $ execute db q r

-- execute_
ex_ :: (HasS3UpDB m, MonadIO m) => Query -> m ()
ex_ q = s3UpDB >>= \db -> liftIO $ execute_ db q

-- tx :: (HasS3UpDB m1, MonadIO m1, HasS3UpDB m2, MonadIO m2) => m1 a -> m2 a
tx :: (HasS3UpDB m, MonadIO m) => ReaderT Connection IO b -> m b
tx a = s3UpDB >>= \db -> liftIO $ withTransaction db (withDB db a)

storeUpload :: (HasS3UpDB m, MonadIO m) => PartialUpload -> m PartialUpload
storeUpload pu@PartialUpload{..} = tx $ do
  ex "insert into uploads (chunk_size, bucket_name, filename, key, upid, post_upload) values (?,?,?,?,?,?)" (
    _pu_chunkSize, _pu_bucket, _pu_filename, _pu_key, _pu_upid, _pu_hook)
  pid <- fromIntegral <$> lid
  let vals = [(pid, fst i) | i <- _pu_parts]
  em "insert into upload_parts (id, part) values (?,?)" vals
  pure pu{_pu_id=pid}

  where
    lid = s3UpDB >>= liftIO . lastInsertRowId

completedUploadPart :: (HasS3UpDB m, MonadIO m) => UploadID -> Int -> ETag -> m ()
completedUploadPart i p e = ex "update upload_parts set etag = ? where id = ? and part = ?" (e, i, p)

completedUpload :: (HasS3UpDB m, MonadIO m) => UploadID -> m ()
completedUpload i = tx $ do
  ex "delete from upload_parts where id = ?" (Only i)
  ex "delete from uploads where id = ?" (Only i)

abortedUpload :: (HasS3UpDB m, MonadIO m) => S3UploadID -> m ()
abortedUpload i = tx $ do
  ex "delete from uploads where upid = ?" (Only i)
  ex_ "delete from upload_parts where id not in (select id from uploads)"

-- Return in order of least work to do.
listPartialUploads :: (HasS3UpDB m, MonadIO m) => m [PartialUpload]
listPartialUploads = do
  segs <- Map.fromListWith (<>) . fmap (\(i,p,e) -> (i, [(p,e)])) <$> q_ "select id, part, etag from upload_parts"
  sortOn (length . filter (isNothing . snd) . _pu_parts) .
    map (\p@PartialUpload{..} -> p{_pu_parts=Map.findWithDefault [] _pu_id segs})
    <$> q_ "select id, chunk_size, bucket_name, filename, key, upid, post_upload from uploads"

listQueuedFiles :: (HasS3UpDB m, MonadIO m) => m [(FilePath, BucketName, ObjectKey)]
listQueuedFiles = q_ "select filename, bucket_name, key from uploads"
