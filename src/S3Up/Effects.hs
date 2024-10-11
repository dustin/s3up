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

module S3Up.Effects where

import           Amazonka                          (Region (..), RequestBody (..))
import qualified Amazonka                          as AWS
import           Amazonka.S3.Types                 (BucketName (..), CompletedMultipartUpload (..), ETag (..),
                                                    ObjectKey (..))
import           Amazonka.S3.Types.MultipartUpload (MultipartUpload)
import           Cleff
import           Control.Monad.Logger              (Loc (..), LogLevel (..), LogSource, LogStr)
import           Control.Monad.Trans.Resource      (ResourceT)
import qualified Data.ByteString.Lazy              as BL
import           S3Up.Types

data OptFX :: Effect where
  GetOptionsFX :: OptFX m Options

makeEffect ''OptFX

data S3FX :: Effect where
  InAWSFX :: (AWS.Env -> ResourceT IO a) -> S3FX m a
  InAWSRegionFX :: Region -> (AWS.Env -> ResourceT IO a) -> S3FX m a

makeEffect ''S3FX

data S3Op :: Effect where
  ListBuckets :: S3Op m [BucketName]
  ListMultipartUploads :: BucketName -> S3Op m [MultipartUpload]
  CreateMultipartUpload :: ObjectKey -> S3Op m S3UploadID
  NewUploadPart :: BucketName -> ObjectKey -> Int -> S3UploadID -> RequestBody -> S3Op m (Maybe ETag)
  CompleteMultipartUpload :: BucketName -> ObjectKey -> S3UploadID -> CompletedMultipartUpload -> S3Op m ()
  AbortMultipartUpload :: ObjectKey -> S3UploadID -> S3Op m ()

makeEffect ''S3Op

data LogFX :: Effect where
  LogFX :: Loc -> LogSource -> LogLevel -> LogStr -> LogFX m ()

makeEffect ''LogFX

data FSFX :: Effect where
  FileSize :: FilePath -> FSFX m Integer
  RemoveFile :: FilePath -> FSFX m ()
  FileChunk :: FilePath -> Integer -> Integer -> FSFX m BL.ByteString

makeEffect ''FSFX

data DBFX :: Effect where
  InitTables :: DBFX m ()
  StoreUpload :: PartialUpload -> DBFX m PartialUpload
  CompletedUpload :: UploadID -> DBFX m ()
  CompletedUploadPart :: UploadID -> Int -> ETag -> DBFX m ()
  AbortedUpload :: S3UploadID -> DBFX m ()
  ListQueuedFiles :: DBFX m [(FilePath, BucketName, ObjectKey)]
  ListPartialUploads :: DBFX m [PartialUpload]

makeEffect ''DBFX
