import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck as QC

import           S3Up

testMkObjectKey :: Assertion
testMkObjectKey = do
  assertEqual "full path" "tmp/file.txt" (mkObjectKey "/some/file.txt" "tmp/file.txt")
  assertEqual "partial path" "tmp/file.txt" (mkObjectKey "/some/file.txt" "tmp/")

tests :: [TestTree]
tests = [
  testCase "mkObjectKey" testMkObjectKey
    ]

main :: IO ()
main = defaultMain $ testGroup "All Tests" tests
