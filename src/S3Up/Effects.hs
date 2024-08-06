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

import           Amazonka                     (Region (..))
import qualified Amazonka                     as AWS
import           Amazonka.S3.Types            (BucketName (..), ETag (..), ObjectKey (..))
import           Cleff
import           Control.Monad.Logger         (Loc (..), LogLevel (..), LogSource, LogStr)
import           Control.Monad.Trans.Resource (ResourceT)
import qualified Data.ByteString.Lazy         as BL
import           S3Up.Types

data OptFX :: Effect where
  GetOptionsFX :: OptFX m Options

makeEffect ''OptFX

data S3FX :: Effect where
  InAWSFX :: (AWS.Env -> ResourceT IO a) -> S3FX m a
  InAWSRegionFX :: Region -> (AWS.Env -> ResourceT IO a) -> S3FX m a

makeEffect ''S3FX

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
