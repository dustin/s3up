module Spec where

import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck as QC

import           S3Up

unit_MkObjectKey :: Assertion
unit_MkObjectKey = do
  assertEqual "full path" "tmp/file.txt" (mkObjectKey "/some/file.txt" "tmp/file.txt")
  assertEqual "partial path" "tmp/file.txt" (mkObjectKey "/some/file.txt" "tmp/")
