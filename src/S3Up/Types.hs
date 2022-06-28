module S3Up.Types where

import           Amazonka.S3.Types (BucketName (..), ETag (..), ObjectKey (..))
import           Data.Text         (Text)

type UploadID = Int
type S3UploadID = Text

data PostUploadHook
  = KeepFile
  | DeleteFile
  deriving (Show, Read, Eq)

data PartialUpload = PartialUpload
  { _pu_id        :: UploadID
  , _pu_chunkSize :: Integer
  , _pu_bucket    :: BucketName
  , _pu_filename  :: FilePath
  , _pu_key       :: ObjectKey
  , _pu_upid      :: S3UploadID
  , _pu_hook      :: PostUploadHook
  , _pu_parts     :: [(Int, Maybe ETag)]
  } deriving Show
