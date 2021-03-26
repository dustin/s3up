{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module S3Up where

import           Control.Applicative          (Alternative (..), (<|>))
import           Control.Concurrent.QSem      (newQSem, signalQSem, waitQSem)
import           Control.Lens
import           Control.Monad                (MonadPlus (..), mzero, void)
import           Control.Monad.Catch          (MonadCatch (..), MonadMask (..), MonadThrow (..), SomeException (..),
                                               bracket_, catch)
import           Control.Monad.IO.Class       (MonadIO (..))
import           Control.Monad.Logger         (Loc (..), LogLevel (..), LogSource, LogStr, MonadLogger (..),
                                               ToLogStr (..), monadLoggerLog)
import           Control.Monad.Reader         (MonadReader, ReaderT (..), asks)
import           Control.Monad.Trans.AWS      (AWST', Credentials (..), envRegion, newEnv, runAWST, runResourceT, send)
import           Control.Monad.Trans.Resource (ResourceT)
import           Control.Retry                (RetryStatus (..), exponentialBackoff, limitRetries, recoverAll)
import qualified Data.ByteString.Lazy         as BL
import           Data.List                    (sort)
import           Data.Maybe                   (isJust)
import           Data.Text                    (Text)
import qualified Data.Text                    as T
import           Data.Time.Clock              (UTCTime)
import           Database.SQLite.Simple       (Connection, withConnection)
import           GHC.Exts                     (IsList (..))
import           Network.AWS.Data.Body        (RqBody (Hashed), ToHashedBody (..))
import qualified Network.AWS.Env              as AWSE
import           Network.AWS.S3
import           System.FilePath.Posix        (takeFileName)
import           System.IO                    (IOMode (..), SeekMode (..), hSeek, withFile)
import           System.Posix.Files           (fileSize, getFileStatus)
import           UnliftIO                     (MonadUnliftIO (..), mapConcurrently, mapConcurrently_)

import qualified S3Up.DB                      as DB
import           S3Up.Logging
import           S3Up.Types

data Command = Create (Either String [(FilePath, ObjectKey)])
             | Upload
             | List
             | InteractiveAbort
             | Abort ObjectKey S3UploadID
             deriving Show

data Options = Options {
  optDBPath            :: FilePath,
  optBucket            :: BucketName,
  optChunkSize         :: Integer,
  optClass             :: StorageClass,
  optVerbose           :: Bool,
  optConcurrency       :: Int,
  optCreateConcurrency :: Int,
  optCommand           :: Command
  } deriving Show

data Env = Env
    { s3Options :: Options
    , s3Region  :: Region
    , dbConn    :: Connection
    , envLogger :: Loc -> LogSource -> LogLevel -> LogStr -> IO ()
    }

newtype S3Up a = S3Up
  { runS3Up :: ReaderT Env IO a
  } deriving (Applicative, Functor, Monad, MonadIO, MonadUnliftIO,
              MonadCatch, MonadThrow, MonadMask, MonadReader Env, MonadFail)

instance (Monad m, MonadReader Env m) => DB.HasS3UpDB m where
  s3UpDB = asks dbConn

instance MonadLogger S3Up where
  monadLoggerLog loc src lvl msg = asks envLogger >>= \l -> liftIO $ l loc src lvl (toLogStr msg)

instance MonadPlus S3Up where
  mzero = error "S3Up zero"

instance Alternative S3Up where
  empty = mzero
  a <|> b = a `catch` \(SomeException _) -> b

mapConcurrentlyLimited :: (MonadMask m, MonadUnliftIO m, Traversable f)
                       => Int
                       -> (a -> m b)
                       -> f a
                       -> m (f b)
mapConcurrentlyLimited n f l = liftIO (newQSem n) >>= \q -> mapConcurrently (b q) l
  where b q x = bracket_ (liftIO (waitQSem q)) (liftIO (signalQSem q)) (f x)

mapConcurrentlyLimited_ :: (MonadMask m, MonadUnliftIO m, Traversable f)
                        => Int
                        -> (a -> m b)
                        -> f a
                        -> m ()
mapConcurrentlyLimited_ n f l = liftIO (newQSem n) >>= \q -> mapConcurrently_ (b q) l
  where b q x = bracket_ (liftIO (waitQSem q)) (liftIO (signalQSem q)) (f x)

mkObjectKey :: FilePath -> ObjectKey -> ObjectKey
mkObjectKey filename = _ObjectKey %~ affix
  where affix p
          | "/" `T.isSuffixOf` p = p <> T.pack (takeFileName filename)
          | otherwise = p

-- Run an action in any AWS location
inAWS :: (MonadCatch m, MonadUnliftIO m) => AWST' AWSE.Env (ResourceT m) a -> m a
inAWS a = newEnv Discover >>= \e -> (runResourceT . runAWST e) a

-- Run an action in the specified region
inAWSRegion :: (MonadCatch m, MonadUnliftIO m) => Region -> AWST' AWSE.Env (ResourceT m) a -> m a
inAWSRegion r a = (newEnv Discover <&> set envRegion r) >>= \awsenv -> (runResourceT . runAWST awsenv) a

-- Run an action at the region appropriate for the given bucket
inAWSBucket :: (MonadCatch m, MonadUnliftIO m) => BucketName -> AWST' AWSE.Env (ResourceT m) a -> m a
inAWSBucket b a = bucketRegion b >>= \r -> inAWSRegion r a

-- Get the correct region for the given bucket
bucketRegion :: (MonadCatch m, MonadUnliftIO m) => BucketName -> m Region
bucketRegion b = view (gblbrsLocationConstraint . _LocationConstraint)
                 <$> (inAWS . send $ getBucketLocation b)

createMultipart :: FilePath -> ObjectKey -> S3Up PartialUpload
createMultipart fp key = do
  fsize <- toInteger . fileSize <$> (liftIO . getFileStatus) fp
  b <- asks (optBucket . s3Options)
  cClass <- asks (optClass . s3Options)
  chunkSize <- asks (optChunkSize . s3Options)
  up <- inAWSBucket b $ send $ createMultipartUpload b key & cmuStorageClass ?~ cClass
  let chunks = [1 .. ceiling @Double (fromIntegral fsize / fromIntegral chunkSize)]
  DB.storeUpload $ PartialUpload 0 chunkSize b fp key (up ^. cmursUploadId . _Just) ((,Nothing) <$> chunks)

completeStr :: PartialUpload -> String
completeStr PartialUpload{..} = show perc <> "% of around " <> show mb <> " MB complete"
  where todo = filter (isJust . snd) _pu_parts
        perc = 100 * length todo `div` length _pu_parts
        mb = fromIntegral _pu_chunkSize * length _pu_parts `div` (1024*1024)

completeUpload :: PartialUpload -> S3Up ()
completeUpload pu@PartialUpload{..} = do
  r <- bucketRegion _pu_bucket
  c <- asks (optConcurrency . s3Options)
  logInfoL ["Uploading remaining parts of ", tshow _pu_filename, " to ", tshow _pu_bucket, ":", tshow _pu_key,
            " ", T.pack (completeStr pu)]
  finished <- fromList . sort <$> mapConcurrentlyLimited c (uc r) _pu_parts
  logInfoL ["Completed all parts of ", tshow _pu_filename, " to ", tshow _pu_bucket, ":", tshow _pu_key]
  let completed = completedMultipartUpload & cmuParts ?~ (uncurry completedPart <$> finished)
  inAWSRegion r $ void . send $ completeMultipartUpload _pu_bucket _pu_key _pu_upid & cMultipartUpload ?~ completed
  DB.completedUpload _pu_id

  where
    uc _ (n,Just e) = pure (n,e)
    uc r (n,Nothing) = do
      body <- liftIO $ withFile _pu_filename ReadMode $ \fh -> do
        hSeek fh AbsoluteSeek ((fromIntegral n - 1) * _pu_chunkSize)
        Hashed . toHashed <$> BL.hGet fh (fromIntegral _pu_chunkSize)
      Just etag <- recoverAll policy $ \rs -> do
        logDbgL ["uploading chunk ", tshow n, " ", tshow body, " attempt ", tshow (rsIterNumber rs)]
        view uprsETag <$> inAWSRegion r (send $ uploadPart _pu_bucket _pu_key n _pu_upid body)
      DB.completedUploadPart _pu_id n etag
      logDbgL ["finished chunk ", tshow n, " ", tshow body, " as ", tshow etag]
      pure (n, etag)

    policy = exponentialBackoff 2000000 <> limitRetries 9

listMultiparts :: BucketName -> S3Up [(UTCTime, ObjectKey, Text)]
listMultiparts b = do
  ups <- inAWSBucket b $ send $ listMultipartUploads b
  pure $ ups ^.. lmursUploads . folded . to (\u -> (u ^?! muInitiated . _Just,
                                                    u ^?! muKey . _Just,
                                                    u ^. muUploadId . _Just))

allBuckets :: S3Up [BucketName]
allBuckets = toListOf (lbrsBuckets . folded . bName) <$> (inAWS . send $ listBuckets)

abortUpload :: ObjectKey -> S3UploadID -> S3Up ()
abortUpload k u = do
  b <- asks (optBucket . s3Options)
  inAWSBucket b $ void . send $ abortMultipartUpload b k u
  DB.abortedUpload u

runIO :: Env -> S3Up a -> IO a
runIO e m = runReaderT (runS3Up m) e

runWithOptions :: Options -> S3Up a -> IO a
runWithOptions o@Options{..} a = withConnection optDBPath $ \db -> do
  DB.initTables db
  let minLvl = if optVerbose then LevelDebug else LevelInfo
  liftIO $ runIO (Env o NorthVirginia db (baseLogger minLvl)) a
