module S3Up.Logging where

import           Control.Monad         (when)
import           Control.Monad.Logger  (Loc (..), LogLevel (..), LogSource, LogStr, MonadLogger (..), fromLogStr,
                                        logDebugN, logErrorN, logInfoN)
import qualified Data.ByteString.Char8 as C8
import           Data.Foldable         (fold)
import           Data.String           (fromString)
import qualified Data.Text             as T
import           System.IO             (stderr)

baseLogger :: LogLevel -> Loc -> LogSource -> LogLevel -> LogStr -> IO ()
baseLogger minLvl _ _ lvl s = when (lvl >= minLvl) $ C8.hPutStrLn stderr (fromLogStr ls)
  where
    ls = prefix <> ": " <> s
    prefix = case lvl of
               LevelDebug   -> "D"
               LevelInfo    -> "I"
               LevelWarn    -> "W"
               LevelError   -> "E"
               LevelOther x -> fromString . T.unpack $ x

logError :: MonadLogger m => T.Text -> m ()
logError = logErrorN

logErrorL :: (Foldable f, MonadLogger m) => f T.Text-> m ()
logErrorL = logErrorN . fold

logInfo :: MonadLogger m => T.Text -> m ()
logInfo = logInfoN

logInfoL :: (Foldable f, MonadLogger m) => f T.Text-> m ()
logInfoL = logInfoN . fold

logDbg :: MonadLogger m => T.Text -> m ()
logDbg = logDebugN

logDbgL :: (Foldable f, MonadLogger m) => f T.Text-> m ()
logDbgL = logInfoN . fold

tshow :: Show a => a -> T.Text
tshow = T.pack . show
