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
import qualified Data.ByteString.Lazy         as BL
import           Data.List                    (sort)
import           Data.Maybe                   (fromJust)
import           Data.Text                    (Text)
import           Data.Time.Clock              (UTCTime)
import           Database.SQLite.Simple       (Connection, withConnection)
import           GHC.Exts                     (IsList (..))
import           Network.AWS.Data.Body        (RqBody (Hashed), ToHashedBody (..))
import qualified Network.AWS.Env              as AWSE
import           Network.AWS.S3
import           System.IO                    (IOMode (..), SeekMode (..), hSeek, withFile)
import           System.Posix.Files           (fileSize, getFileStatus)
import           UnliftIO                     (MonadUnliftIO (..), mapConcurrently)

import           S3Up.DB
import           S3Up.Logging

data Options = Options {
  optDBPath      :: FilePath,
  optBucket      :: BucketName,
  optChunkSize   :: Integer,
  optVerbose     :: Bool,
  optConcurrency :: Int,
  optArgv        :: [String]
  } deriving Show

data Env = Env
    { s3Options  :: Options
    , s3Region   :: Region
    , dbConn     :: Connection
    , envLoggers :: [Loc -> LogSource -> LogLevel -> LogStr -> IO ()]
    }

newtype S3Up a = S3Up
  { runS3Up :: ReaderT Env IO a
  } deriving (Applicative, Functor, Monad, MonadIO, MonadUnliftIO,
              MonadCatch, MonadThrow, MonadMask, MonadReader Env, MonadFail)

instance (Monad m, MonadReader Env m) => HasS3UpDB m where
  s3UpDB = asks dbConn

instance MonadLogger S3Up where
  monadLoggerLog loc src lvl msg = mapM_ (\l -> liftIO $ l loc src lvl (toLogStr msg)) =<< asks envLoggers

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

inAWS :: (MonadCatch m, MonadUnliftIO m) => Region -> AWST' AWSE.Env (ResourceT m) a -> m a
inAWS r a = (newEnv Discover <&> set envRegion r) >>= \awsenv -> (runResourceT . runAWST awsenv) a

inAWSBucket :: (MonadCatch m, MonadUnliftIO m) => BucketName -> AWST' AWSE.Env (ResourceT m) a -> m a
inAWSBucket b a = bucketRegion b >>= \r -> inAWS r a

-- Get the correct region for the given bucket
bucketRegion :: (MonadCatch m, MonadUnliftIO m) => BucketName -> m Region
bucketRegion b = do
  br <- newEnv Discover >>= \e -> (runResourceT . runAWST e) . send $ getBucketLocation b
  pure (br ^. gblbrsLocationConstraint . _LocationConstraint)

createMultipart :: FilePath -> ObjectKey -> S3Up PartialUpload
createMultipart fp key = do
  fsize <- toInteger . fileSize <$> (liftIO . getFileStatus) fp
  b <- asks (optBucket . s3Options)
  chunkSize <- asks (optChunkSize . s3Options)
  up <- inAWSBucket b $ send $ createMultipartUpload b key
  let chunks = [1 .. ceiling @Double (fromIntegral fsize / fromIntegral chunkSize)]
  storeUpload $ PartialUpload 0 chunkSize b fp key (up ^. cmursUploadId . _Just) ((,Nothing) <$> chunks)

completeUpload :: PartialUpload -> S3Up ()
completeUpload PartialUpload{..} = do
  r <- bucketRegion _pu_bucket
  c <- asks (optConcurrency . s3Options)
  logInfoL ["Uploading remaining parts of ", tshow _pu_filename, " to ", tshow _pu_bucket, ":", tshow _pu_key]
  finished <- fromList . sort <$> mapConcurrentlyLimited c (uc r) _pu_parts
  logInfoL ["Completed all parts of ", tshow _pu_filename, " to ", tshow _pu_bucket, ":", tshow _pu_key]
  let completed = completedMultipartUpload & cmuParts ?~ (uncurry completedPart <$> finished)
  inAWS r $ void . send $ completeMultipartUpload _pu_bucket _pu_key _pu_upid & cMultipartUpload ?~ completed
  completedUpload _pu_id

  where
    uc _ (n,Just e) = pure (n,e)
    uc r (n,Nothing) = do
      body <- liftIO $ withFile _pu_filename ReadMode $ \fh -> do
        hSeek fh AbsoluteSeek ((fromIntegral n - 1) * _pu_chunkSize)
        Hashed . toHashed <$> BL.hGet fh (fromIntegral _pu_chunkSize)
      logDbgL ["uploading chunk ", tshow n, " ", tshow body]
      res <- inAWS r $ send $ uploadPart _pu_bucket _pu_key n _pu_upid body
      let Just etag = res ^. uprsETag
      completedUploadPart _pu_id n etag
      logDbgL ["finished chunk ", tshow n, " ", tshow body, " as ", tshow etag]
      pure (n, etag)

listMultiparts :: S3Up [(UTCTime, ObjectKey, Text)]
listMultiparts = do
  b <- asks (optBucket . s3Options)
  ups <- inAWSBucket b $ send $ listMultipartUploads b
  pure $ ups ^.. lmursUploads . folded . to (\u -> (fromJust (u ^? muInitiated . _Just),
                                                    fromJust (u ^? muKey . _Just),
                                                    u ^. muUploadId . _Just))

abortUpload :: ObjectKey -> S3UploadID -> S3Up ()
abortUpload k u = do
  b <- asks (optBucket . s3Options)
  inAWSBucket b $ void . send $ abortMultipartUpload b k u
  abortedUpload u

runIO :: Env -> S3Up a -> IO a
runIO e m = runReaderT (runS3Up m) e

runWithOptions :: Options -> S3Up a -> IO a
runWithOptions o@Options{..} a = withConnection optDBPath $ \db -> do
  initTables db
  let o' = o{optArgv = tail optArgv}
      minLvl = if optVerbose then LevelDebug else LevelInfo
  liftIO $ runIO (Env o' NorthVirginia db [baseLogger minLvl]) a
