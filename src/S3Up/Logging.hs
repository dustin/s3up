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

module S3Up.Logging where

import           Cleff
import           Control.Monad         (when)
import           Control.Monad.Logger  (Loc (..), LogLevel (..), LogSource, LogStr, fromLogStr)
import qualified Data.ByteString.Char8 as C8
import           Data.Foldable         (fold)
import           Data.String           (fromString)
import qualified Data.Text             as T
import           S3Up.Effects
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

runLogFX :: (IOE :> es) => Bool -> Eff (LogFX : es) a -> Eff es a
runLogFX verbose = interpretIO \case
  LogFX loc src lvl' msg -> liftIO $ baseLogger minLvl loc src lvl' msg
  where minLvl = if verbose then LevelDebug else LevelInfo

-- Text loggers
logError, logInfo, logDbg :: [IOE, LogFX] :>> es => T.Text -> Eff es ()

-- List loggers
logErrorL, logInfoL, logDbgL :: (Foldable f, [IOE, LogFX] :>> es) => f T.Text -> Eff es ()

logError = liftIO . print
logErrorL = logError . fold

logInfo = liftIO . print
logInfoL = logInfo . fold -- logInfoN . fold

logDbg = liftIO . print
logDbgL = logDbg . fold -- logDebugN . fold

tshow :: Show a => a -> T.Text
tshow = T.pack . show
