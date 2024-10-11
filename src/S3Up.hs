{-# LANGUAGE BlockArguments             #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedLabels           #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module S3Up where

import           Amazonka                     (Region (..), RequestBody (Hashed), ToHashedBody (..), _Time, send)
import qualified Amazonka                     as AWS
import           Amazonka.S3                  (BucketName, ObjectKey, _LocationConstraint, _ObjectKey,
                                               newCompletedMultipartUpload, newCompletedPart, newGetBucketLocation)
import           Cleff                        hiding (send)
import           Cleff.Error
import           Control.Concurrent.QSem      (newQSem, signalQSem, waitQSem)
import           Control.Lens
import           Control.Monad                (when)
import           Control.Monad.Catch          (Exception (..), MonadMask (..), bracket_)
import           Control.Monad.Trans.Resource (ResourceT)
import           Control.Retry                (RetryStatus (..), exponentialBackoff, limitRetries, recoverAll)
import           Data.Foldable                (fold)
import           Data.Generics.Labels         ()
import           Data.List                    (sort)
import           Data.Maybe                   (fromJust, isJust)
import           Data.String                  (fromString)
import           Data.Text                    (Text)
import qualified Data.Text                    as T
import           Data.Time.Clock              (UTCTime)
import           GHC.Exts                     (IsList (..))
import           System.FilePath.Posix        (takeFileName)
import           UnliftIO                     (mapConcurrently, mapConcurrently_)

import           S3Up.Effects
import           S3Up.Logging
import           S3Up.Types

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

mkObjectKey :: FilePath -> String -> ObjectKey
mkObjectKey filename = (_ObjectKey %~ affix) . fromString
  where affix p
          | "/" `T.isSuffixOf` p = p <> T.pack (takeFileName filename)
          | otherwise = p

-- Run an action in any AWS location

inAWS :: S3FX :> es => (AWS.Env -> ResourceT IO a) -> Eff es a
inAWS = inAWSFX

inAWSRegion :: S3FX :> es => Region -> (AWS.Env  -> ResourceT IO a) -> Eff es a
inAWSRegion r = inAWSRegionFX r

bucketRegion :: S3FX :> es => BucketName -> Eff es Region
bucketRegion b = view (#locationConstraint . _LocationConstraint) <$> (inAWS . flip send $ newGetBucketLocation b)

inAWSBucket :: S3FX :> es => BucketName -> (AWS.Env -> ResourceT IO a) -> Eff es a
inAWSBucket b a = bucketRegion b >>= flip inAWSRegion a

calcMinSize :: Int -> Int
calcMinSize fsize = max (5*mb) (ceiling @Double (fromIntegral fsize / 10000))
  where
    mb = 1024 * 1024

data ETooBig = ETooBig Int Int

instance Show ETooBig where
  show (ETooBig fs cs) = fold ["This file would have too many chunks: ",show cs, " (max is 10,000).  ",
                         "Try using a chunk size of ", show (calcMinSize fs)]

instance Exception ETooBig

createMultipart :: ([S3Op, OptFX, FSFX, DBFX, Error ETooBig] :>> es) => PostUploadHook -> FilePath -> ObjectKey -> Eff es PartialUpload
createMultipart hook fp key = do
  fsize <- fileSize fp
  b <- optBucket <$> getOptionsFX
  chunkSize <- optChunkSize <$> getOptionsFX
  let chunks = [1 .. ceiling @Double (fromIntegral fsize / fromIntegral chunkSize)]
  when (length chunks > 10000) $ throwError (ETooBig (fromIntegral fsize) (length chunks))
  upid <- createMultipartUpload key
  storeUpload $ PartialUpload 0 chunkSize b fp key upid hook ((,Nothing) <$> chunks)

completeStr :: PartialUpload -> String
completeStr PartialUpload{..} = show perc <> "% of around " <> show mb <> " MB complete"
  where todo = filter (isJust . snd) _pu_parts
        perc = 100 * length todo `div` length _pu_parts
        mb = fromIntegral _pu_chunkSize * length _pu_parts `div` (1024*1024)

completeUpload ::  [S3Op, OptFX, FSFX, DBFX, LogFX, IOE] :>> es => PartialUpload -> Eff es ()
completeUpload pu@PartialUpload{..} = do
  c <- optConcurrency <$> getOptionsFX
  logInfoL ["Uploading remaining parts of ", tshow _pu_filename, " to ", tshow _pu_bucket, ":", tshow _pu_key,
            " ", T.pack (completeStr pu)]
  finished <- fromList . sort <$> mapConcurrentlyLimited c uc _pu_parts
  logInfoL ["Completed all parts of ", tshow _pu_filename, " to ", tshow _pu_bucket, ":", tshow _pu_key]
  let completed = newCompletedMultipartUpload & #parts ?~ (uncurry newCompletedPart <$> finished)
  completeMultipartUpload _pu_bucket _pu_key _pu_upid completed
  completedUpload _pu_id
  when (_pu_hook == DeleteFile) $ do
    logInfoL ["Deleting ", tshow _pu_filename]
    removeFile _pu_filename

  where
    uc (n,Just e) = pure (n,e)
    uc (n,Nothing) = do
      body <- Hashed . toHashed <$> fileChunk _pu_filename ((fromIntegral n - 1) * _pu_chunkSize) _pu_chunkSize
      etag <- recoverAll policy $ \rs -> do
        logDbgL ["uploading chunk ", tshow n, " ", tshow body, " attempt ", tshow (rsIterNumber rs)]
        newUploadPart _pu_bucket _pu_key n _pu_upid body
      completedUploadPart _pu_id n (fromJust etag)
      logDbgL ["finished chunk ", tshow n, " ", tshow body, " as ", tshow etag]
      pure (n, fromJust etag)

    policy = exponentialBackoff 2000000 <> limitRetries 9

listMultiparts :: S3Op :> es => BucketName -> Eff es [(UTCTime, ObjectKey, Text)]
listMultiparts b = fmap resolve <$> listMultipartUploads b
  where
    resolve u = (u ^?! #initiated . _Just . _Time, u ^?! #key . _Just, u ^. #uploadId . _Just)

allBuckets :: S3Op :> es => Eff es [BucketName]
allBuckets = listBuckets

abortUpload :: ([DBFX, S3Op, OptFX] :>> es) => ObjectKey -> S3UploadID -> Eff es ()
abortUpload k u = abortMultipartUpload k u *> abortedUpload u
