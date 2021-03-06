{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}

module Git where

import Control.Monad
import GHC.Generics

import qualified Data.Text as T
import System.Process

import Network.URI
import Data.Aeson
import Servant

newtype GitRepo = GitRepo FilePath

-- | A range of commits which we can merge.
data CommitRange = CommitRange { baseCommit :: SHA
                               , headCommit :: SHA
                               }
                 deriving (Show, Generic)
instance ToJSON CommitRange
instance FromJSON CommitRange

runGit :: GitRepo -> String -> [String] -> String -> IO String
runGit (GitRepo path) cmd args = readProcess "git" (["-C", path, cmd] ++ args)

resolveRef :: GitRepo -> Ref -> IO SHA
resolveRef repo ref =
    SHA . T.pack <$> runGit repo "rev-parse" [showRef ref] ""

rebase :: GitRepo
       -> CommitRange  -- ^ base and head
       -> SHA          -- ^ onto
       -> IO CommitRange
rebase repo (CommitRange base head) onto =
    CommitRange onto . SHA . T.pack <$> runGit repo "rebase"
        ["--onto", showSHA onto, showSHA base, showSHA head] ""

checkout :: GitRepo
         -> Bool -- ^ force
         -> Commit
         -> IO ()
checkout repo force commit =
    void $ runGit repo "checkout" (if force then ["-f", ref] else [ref]) ""
  where
    ref = showCommit commit

mergeBase :: GitRepo -> Commit -> Commit -> IO SHA
mergeBase repo a b =
    SHA . T.pack <$> runGit repo "merge-base" [showCommit a, showCommit b] ""

newtype SHA = SHA { getSHA :: T.Text }
            deriving (Show, Eq, Ord, ToJSON, FromJSON, FromHttpApiData, ToHttpApiData)

newtype Ref = Ref { getRef :: T.Text }
            deriving (Show, Eq, Ord, ToJSON, FromJSON)

instance FromHttpApiData Ref where
    parseUrlPiece = Right . Ref . T.pack . unEscapeString . T.unpack

instance ToHttpApiData Ref where
    toUrlPiece (Ref x) = T.pack $ escapeURIString isUnescapedInURIComponent (T.unpack x)

data Commit = CommitSha SHA
            | CommitRef Ref

showCommit :: Commit -> String
showCommit (CommitSha sha) = showSHA sha
showCommit (CommitRef ref) = showRef ref

showSHA :: SHA -> String
showSHA (SHA ref) = T.unpack ref

showRef :: Ref -> String
showRef (Ref ref) = T.unpack ref

data UpdateRefAction = UpdateRef Ref SHA (Maybe SHA)
                     | CreateRef Ref SHA
                     | DeleteRef Ref (Maybe SHA)
                     deriving (Show)

zeroSHA :: SHA
zeroSHA = SHA $ T.replicate 40 (T.pack "0")

updateRefs :: GitRepo -> [UpdateRefAction] -> IO ()
updateRefs repo actions =
    void $ runGit repo "update-ref" ["--stdin"]
        $ unlines $ map toLine actions
  where
    sRef = T.unpack . getRef
    sSHA = T.unpack . getSHA
    toLine (UpdateRef ref new (Just old)) =
        unwords ["update", sRef ref, sSHA new, sSHA old]
    toLine (UpdateRef ref new Nothing) =
        unwords ["update", sRef ref, sSHA new]
    toLine (CreateRef ref new) =
        unwords ["create", sRef ref, sSHA new]
    toLine (DeleteRef ref (Just old)) =
        unwords ["delete", sRef ref, sSHA old]
    toLine (DeleteRef ref Nothing) =
        unwords ["delete", sRef ref]
