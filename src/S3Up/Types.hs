module S3Up.Types where

import           Amazonka.S3.Types  (BucketName (..), ETag (..), ObjectKey (..), StorageClass (..))
import           Data.List.NonEmpty (NonEmpty)
import           Data.Text          (Text)

type UploadID = Int
type S3UploadID = Text

data PostUploadHook
  = KeepFile
  | DeleteFile
  deriving (Show, Read, Eq, Bounded, Enum)

data PartialUpload = PartialUpload
  { _pu_id        :: UploadID
  , _pu_chunkSize :: Integer
  , _pu_bucket    :: BucketName
  , _pu_filename  :: FilePath
  , _pu_key       :: ObjectKey
  , _pu_upid      :: S3UploadID
  , _pu_hook      :: PostUploadHook
  , _pu_parts     :: [(Int, Maybe ETag)]
  } deriving (Show, Eq)

data Command = Create (Either String (NonEmpty (FilePath, ObjectKey)))
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
  optHook              :: PostUploadHook,
  optCommand           :: Command
  } deriving Show
