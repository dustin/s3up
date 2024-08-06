{-# LANGUAGE BlockArguments       #-}
{-# LANGUAGE ConstraintKinds      #-}
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE KindSignatures       #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module S3Up.DB (runDBFX) where

import           Amazonka.Data.ByteString         (ToByteString (..))
import           Amazonka.Data.Text               (FromText, ToText (..), fromText)
import           Amazonka.S3.Types                (BucketName (..), ETag (..), ObjectKey (..))
import           Cleff
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

import           S3Up.Effects                     (DBFX (..))
import           S3Up.Types

runDBFX :: IOE :> es => Connection -> Eff (DBFX : es) a -> Eff es a
runDBFX db = interpretIO \case
  InitTables                -> initTables db
  StoreUpload pu            -> storeUpload db pu
  CompletedUpload i         -> completedUpload db i
  CompletedUploadPart i p e -> completedUploadPart db i p e
  AbortedUpload i           -> abortedUpload db i
  ListQueuedFiles           -> listQueuedFiles db
  ListPartialUploads        -> listPartialUploads db

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
q_ :: FromRow r => Connection -> Query -> IO [r]
q_ db q = query_ db q

-- execute many
em :: ToRow r => Connection -> Query -> [r] -> IO ()
em = executeMany

-- execute
ex :: ToRow r => Connection -> Query -> r -> IO ()
ex = execute

-- execute_
ex_ :: Connection -> Query -> IO ()
ex_ = execute_

-- tx :: (HasS3UpDB m1, MonadIO m1, HasS3UpDB m2, MonadIO m2) => m1 a -> m2 a
tx :: Connection -> IO b -> IO b
tx db = withTransaction db

storeUpload :: Connection -> PartialUpload -> IO PartialUpload
storeUpload db pu@PartialUpload{..} = tx db $ do
  ex db "insert into uploads (chunk_size, bucket_name, filename, key, upid, post_upload) values (?,?,?,?,?,?)" (
    _pu_chunkSize, _pu_bucket, _pu_filename, _pu_key, _pu_upid, _pu_hook)
  pid <- fromIntegral <$> lid
  let vals = [(pid, fst i) | i <- _pu_parts]
  em db "insert into upload_parts (id, part) values (?,?)" vals
  pure pu{_pu_id=pid}

  where
    lid = lastInsertRowId db

completedUploadPart :: Connection -> UploadID -> Int -> ETag -> IO ()
completedUploadPart db i p e = ex db "update upload_parts set etag = ? where id = ? and part = ?" (e, i, p)

completedUpload :: Connection -> UploadID -> IO ()
completedUpload db i = tx db $ do
  ex db "delete from upload_parts where id = ?" (Only i)
  ex db "delete from uploads where id = ?" (Only i)

abortedUpload :: Connection -> S3UploadID -> IO ()
abortedUpload db i = tx db $ do
  ex db "delete from uploads where upid = ?" (Only i)
  ex_ db "delete from upload_parts where id not in (select id from uploads)"

-- Return in order of least work to do.
listPartialUploads :: Connection -> IO [PartialUpload]
listPartialUploads db = do
  segs <- Map.fromListWith (<>) . fmap (\(i,p,e) -> (i, [(p,e)])) <$> q_ db "select id, part, etag from upload_parts"
  sortOn (length . filter (isNothing . snd) . _pu_parts) .
    map (\p@PartialUpload{..} -> p{_pu_parts=Map.findWithDefault [] _pu_id segs})
    <$> q_ db "select id, chunk_size, bucket_name, filename, key, upid, post_upload from uploads"

listQueuedFiles :: Connection -> IO [(FilePath, BucketName, ObjectKey)]
listQueuedFiles db = q_ db "select filename, bucket_name, key from uploads"
