{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module S3Up.DB where

import           Amazonka                         (FromText, ToByteString (..), ToText (..), fromText)
import           Amazonka.S3.Types                (BucketName (..), ETag (..), ObjectKey (..))
import           Control.Monad.IO.Class           (MonadIO (..))
import           Control.Monad.Reader             (ReaderT (..), ask, runReaderT)
import qualified Data.ByteString                  as BS
import           Data.Coerce                      (coerce)
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

storeUpload :: (HasS3UpDB m, MonadIO m) => PartialUpload -> m PartialUpload
storeUpload pu@PartialUpload{..} = liftIO . ins =<< s3UpDB
  where
    ins db = withTransaction db $ do
      execute db "insert into uploads (chunk_size, bucket_name, filename, key, upid, post_upload) values (?,?,?,?,?,?)" (
        _pu_chunkSize, _pu_bucket, _pu_filename, _pu_key, _pu_upid, _pu_hook)
      pid <- fromIntegral <$> lastInsertRowId db
      let vals = [(pid, fst i) | i <- _pu_parts]
      executeMany db "insert into upload_parts (id, part) values (?,?)" vals
      pure pu{_pu_id=pid}

completedUploadPart :: (HasS3UpDB m, MonadIO m) => UploadID -> Int -> ETag -> m ()
completedUploadPart i p e = liftIO . up =<< s3UpDB
  where up db = execute db "update upload_parts set etag = ? where id = ? and part = ?" (e, i, p)

completedUpload :: (HasS3UpDB m, MonadIO m) => UploadID -> m ()
completedUpload i = liftIO . up =<< s3UpDB
  where up db = withTransaction db $ do
          execute db "delete from upload_parts where id = ?" (Only i)
          execute db "delete from uploads where id = ?" (Only i)

abortedUpload :: (HasS3UpDB m, MonadIO m) => S3UploadID -> m ()
abortedUpload i = liftIO . up =<< s3UpDB
  where up db = withTransaction db $ do
          execute db "delete from uploads where upid = ?" (Only i)
          execute_ db "delete from upload_parts where id not in (select id from uploads)"

-- Return in order of least work to do.
listPartialUploads :: (HasS3UpDB m, MonadIO m) => m [PartialUpload]
listPartialUploads = liftIO . sel =<< s3UpDB
  where
    sel db = do
      segs <- Map.fromListWith (<>) . fmap (\(i,p,e) -> (i, [(p,e)])) <$> query_ db "select id, part, etag from upload_parts"
      sortOn (length . filter (isNothing . snd) . _pu_parts) .
        map (\p@PartialUpload{..} -> p{_pu_parts=Map.findWithDefault [] _pu_id segs})
        <$> query_ db "select id, chunk_size, bucket_name, filename, key, upid, post_upload from uploads"

listQueuedFiles :: (HasS3UpDB m, MonadIO m) => m [FilePath]
listQueuedFiles = liftIO . coerce . sel =<< s3UpDB
  where
    sel :: Connection -> IO [Only FilePath]
    sel db = query_ db "select filename from uploads"
