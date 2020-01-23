-- Hoff -- A gatekeeper for your commits
-- Copyright 2016 Ruud van Asseldonk
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- A copy of the License has been included in the root of the repository.

{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Logic
(
  Action,
  ActionFree (..),
  Event (..),
  EventQueue,
  dequeueEvent,
  enqueueEvent,
  enqueueStopSignal,
  ensureCloned,
  handleEvent,
  newEventQueue,
  newStateVar,
  proceedUntilFixedPoint,
  readStateVar,
  runAction,
  tryIntegratePullRequest,
  updateStateVar,
)
where

import Control.Concurrent.STM.TMVar (TMVar, newTMVar, readTMVar, swapTMVar)
import Control.Concurrent.STM.TBQueue (TBQueue, newTBQueue, readTBQueue, writeTBQueue)
import Control.Exception (assert)
import Control.Monad (mfilter, when, void)
import Control.Monad.Free (Free (..), foldFree, liftF, hoistFree)
import Control.Monad.STM (atomically)
import Data.Maybe (fromJust, fromMaybe, isJust, maybe)
import Data.Text (Text)
import Data.Text.Format.Params (Params)
import Data.Text.Lazy (toStrict)
import Data.Functor.Sum (Sum (InL, InR))
import GHC.Natural (Natural)

import qualified Data.Text as Text
import qualified Data.Text.Format as Text

import Configuration (ProjectConfiguration, TriggerConfiguration)
import Git (Branch (..), GitOperation, GitOperationFree, PushResult (..), Sha (..))
import GithubApi (GithubOperation, GithubOperationFree)
import Project (BuildStatus (..))
import Project (IntegrationStatus (..))
import Project (ProjectState)
import Project (PullRequest)
import Types (PullRequestId (..), Username (..))

import qualified Git
import qualified GithubApi
import qualified Project as Pr
import qualified Configuration as Config

-- Conversion function because of Haskell string type madness. This is just
-- Text.format, but returning a strict Text instead of a lazy one.
-- TODO: Extract into utility module and avoid duplication?
format :: Params ps => Text.Format -> ps -> Text
format formatString params = toStrict $ Text.format formatString params

data ActionFree a
  = TryIntegrate Text (Branch, Sha) (Maybe Sha -> a)
  | TryPromote Branch Sha (PushResult -> a)
  | LeaveComment PullRequestId Text a
  | IsReviewer Username (Bool -> a)
  deriving (Functor)

type Action = Free ActionFree

type Operation = Free (Sum GitOperationFree GithubOperationFree)

doGit :: GitOperation a -> Operation a
doGit = hoistFree InL

doGithub :: GithubOperation a -> Operation a
doGithub = hoistFree InR

tryIntegrate :: Text -> (Branch, Sha) -> Action (Maybe Sha)
tryIntegrate mergeMessage candidate = liftF $ TryIntegrate mergeMessage candidate id

-- Try to fast-forward the remote target branch (usually master) to the new sha.
-- Before doing so, force-push that thas to the pull request branch, and after
-- success, delete the pull request branch. These steps ensure that Github marks
-- the pull request as merged, rather than closed.
tryPromote :: Branch -> Sha -> Action PushResult
tryPromote prBranch newHead = liftF $ TryPromote prBranch newHead id

-- Leave a comment on the given pull request.
leaveComment :: PullRequestId -> Text -> Action ()
leaveComment pr body = liftF $ LeaveComment pr body ()

-- Check if this user is allowed to issue merge commands.
isReviewer :: Username -> Action Bool
isReviewer username = liftF $ IsReviewer username id

-- Interpreter that translates high-level actions into more low-level ones.
runAction :: ProjectConfiguration -> Action a -> Operation a
runAction config = foldFree $ \case
  TryIntegrate message (ref, sha) cont -> do
    doGit $ ensureCloned config
    -- TODO: Change types in config to be 'Branch', not 'Text'.
    maybeSha <- doGit $ Git.tryIntegrate
      message
      ref
      sha
      (Git.Branch $ Config.branch config)
      (Git.Branch $ Config.testBranch config)
    pure $ cont maybeSha

  TryPromote prBranch sha cont -> do
    doGit $ ensureCloned config
    doGit $ Git.forcePush sha prBranch
    pushResult <- doGit $ Git.push sha (Git.Branch $ Config.branch config)
    pure $ cont pushResult

  LeaveComment pr body cont -> do
    doGithub $ GithubApi.leaveComment pr body
    pure cont

  IsReviewer username cont -> do
    hasPushAccess <- doGithub $ GithubApi.hasPushAccess username
    pure $ cont hasPushAccess

ensureCloned :: ProjectConfiguration -> GitOperation ()
ensureCloned config =
  let
    url = format "git@github.com:{}/{}.git" (Config.owner config, Config.repository config)
    -- Just a very basic retry, no exponential backoff or anything. Also, the
    -- reason that the clone fails might not be a temporary issue, but still;
    -- retrying is the best thing we could do.
    cloneWithRetry 0 = pure ()
    cloneWithRetry (triesLeft :: Int) = do
      result <- Git.clone (Git.RemoteUrl url)
      case result of
        Git.CloneOk -> pure ()
        Git.CloneFailed -> cloneWithRetry (triesLeft - 1)
  in do
    exists <- Git.doesGitDirectoryExist
    when (not exists) (cloneWithRetry 3)
    pure ()

data Event
  -- GitHub events
  = PullRequestOpened PullRequestId Branch Sha Text Username -- PR, branch, sha, title, author.
  -- The commit changed event may contain false positives: it may be received
  -- even if the commit did not really change. This is because GitHub just
  -- sends a "something changed" event along with the new state.
  | PullRequestCommitChanged PullRequestId Sha -- PR, new sha.
  | PullRequestClosed PullRequestId            -- PR.
  | CommentAdded PullRequestId Username Text   -- PR, author and body.
  -- CI events
  | BuildStatusChanged Sha BuildStatus
  deriving (Eq, Show)

type EventQueue = TBQueue (Maybe Event)
type StateVar = TMVar ProjectState

-- Creates a new event queue with the given maximum capacity.
newEventQueue :: Natural -> IO EventQueue
newEventQueue capacity = atomically $ newTBQueue capacity

-- Enqueues an event, blocks if the queue is full.
enqueueEvent :: EventQueue -> Event -> IO ()
enqueueEvent queue event = atomically $ writeTBQueue queue $ Just event

-- Signals the event loop to stop after processing all events
-- currently in the queue.
enqueueStopSignal :: EventQueue -> IO ()
enqueueStopSignal queue = atomically $ writeTBQueue queue Nothing

-- Dequeue an event or stop signal from an event queue.
dequeueEvent :: EventQueue -> IO (Maybe Event)
dequeueEvent queue = atomically $ readTBQueue queue

-- Creates a new project state variable.
newStateVar :: ProjectState -> IO StateVar
newStateVar initialState = atomically $ newTMVar initialState

-- Put a new value in the project state variable, discarding the previous one.
updateStateVar :: StateVar -> ProjectState -> IO ()
updateStateVar var state = void $ atomically $ swapTMVar var state

-- Read the most recent value from the project state variable.
readStateVar :: StateVar -> IO ProjectState
readStateVar var = atomically $ readTMVar var

-- Handle a single event, but don't take any other actions. To complete handling
-- of the event, we must also call `proceed` on the state until we reach a fixed
-- point. This is handled by `handleEvent`.
handleEventInternal
  :: TriggerConfiguration
  -> Event
  -> ProjectState
  -> Action ProjectState
handleEventInternal triggerConfig event = case event of
  PullRequestOpened pr branch sha title author -> handlePullRequestOpened pr branch sha title author
  PullRequestCommitChanged pr sha -> handlePullRequestCommitChanged pr sha
  PullRequestClosed pr            -> handlePullRequestClosed pr
  CommentAdded pr author body     -> handleCommentAdded triggerConfig pr author body
  BuildStatusChanged sha status   -> handleBuildStatusChanged sha status

handlePullRequestOpened
  :: PullRequestId
  -> Branch
  -> Sha
  -> Text
  -> Username
  -> ProjectState
  -> Action ProjectState
handlePullRequestOpened pr branch sha title author =
  return . Pr.insertPullRequest pr branch sha title author

handlePullRequestCommitChanged :: PullRequestId -> Sha -> ProjectState -> Action ProjectState
handlePullRequestCommitChanged pr newSha state =
  -- If the commit changes, pretend that the PR was closed. This forgets about
  -- approval and build status. Then pretend a new PR was opened, with the same
  -- author as the original one, but with the new sha.
  let
    closedState = handlePullRequestClosed pr state
    update pullRequest =
      let
        oldSha   = Pr.sha pullRequest
        branch   = Pr.branch pullRequest
        title    = Pr.title pullRequest
        author   = Pr.author pullRequest
        newState = closedState >>= handlePullRequestOpened pr branch newSha title author
      in
        -- If the change notification was a false positive, ignore it.
        if oldSha == newSha then return state else newState
  in
    -- If the pull request was not present in the first place, do nothing.
    maybe (return state) update $ Pr.lookupPullRequest pr state

handlePullRequestClosed :: PullRequestId -> ProjectState -> Action ProjectState
handlePullRequestClosed pr state = return $ Pr.deletePullRequest pr state {
  -- If the PR was the current integration candidate, reset that to Nothing.
  Pr.integrationCandidate = mfilter (/= pr) $ Pr.integrationCandidate state
}

-- Returns whether the message is a command that instructs us to merge the PR.
-- If the trigger prefix is "@hoffbot", a command "@hoffbot merge" would
-- indicate approval.
isMergeCommand :: TriggerConfiguration -> Text -> Bool
isMergeCommand config message =
  let
    messageCaseFold = Text.toCaseFold $ Text.strip message
    prefixCaseFold = Text.toCaseFold $ Config.commentPrefix config
  in
    -- Check if the prefix followed by ` merge` occurs within the message. We opt
    -- to include the space here, instead of making it part of the prefix, because
    -- having the trailing space in config is something that is easy to get wrong.
    (mappend prefixCaseFold " merge") `Text.isInfixOf` messageCaseFold

-- Mark the pull request as approved by the approver, and leave a comment to
-- acknowledge that.
approvePullRequest :: PullRequestId -> Username -> ProjectState -> Action ProjectState
approvePullRequest pr approver state = do
  let newState = Pr.updatePullRequest pr (\pullRequest -> pullRequest { Pr.approvedBy = Just approver }) state
  leaveComment pr $ case Pr.getQueuePosition pr state of
    0 -> format "Pull request approved by @{}, rebasing now." [approver]
    1 -> format "Pull request approved by @{}, waiting for rebase at the front of the queue." [approver]
    n -> format "Pull request approved by @{}, waiting for rebase behind {} pull requests." (approver, n)
  pure newState

handleCommentAdded
  :: TriggerConfiguration
  -> PullRequestId
  -> Username
  -> Text
  -> ProjectState
  -> Action ProjectState
handleCommentAdded triggerConfig pr author body state =
  if Pr.existsPullRequest pr state
    -- Check if the commment is a merge command, and if it is, check if the
    -- author is allowed to approve. Comments by users with push access happen
    -- frequently, but most comments are not merge commands, and checking that
    -- a user has push access requires an API call.
    then do
      isApproved <- if isMergeCommand triggerConfig body
        then isReviewer author
        else pure False
      if isApproved
        -- The PR has now been approved by the author of the comment.
        then approvePullRequest pr author state
        else pure state

    -- If the pull request is not in the state, ignore the comment.
    else pure state

handleBuildStatusChanged :: Sha -> BuildStatus -> ProjectState -> Action ProjectState
handleBuildStatusChanged buildSha newStatus state =
  -- If there is an integration candidate, and its integration sha matches that
  -- of the build, then update the build status for that pull request. Otherwise
  -- do nothing.
  let matchesBuild pr = case Pr.integrationStatus pr of
        Integrated candidateSha -> candidateSha == buildSha
        _                       -> False
      newState = do
        candidateId <- Pr.integrationCandidate state
        -- Set the build status only if the build sha matches that of the
        -- integration candidate.
        _ <- mfilter matchesBuild $ Pr.lookupPullRequest candidateId state
        return $ Pr.setBuildStatus candidateId newStatus state
  in return $ fromMaybe state newState

-- Determines if there is anything to do, and if there is, generates the right
-- actions and updates the state accordingly. For example, if the current
-- integration candidate has been integrated (and is no longer a candidate), we
-- should find a new candidate. Or after the pull request for which a build is
-- in progress is closed, we should find a new candidate.
proceed :: ProjectState -> Action ProjectState
proceed state = case Pr.getIntegrationCandidate state of
  -- If there is a candidate, nothing needs to be done. TODO: not even if the
  -- build has finished for the candidate? Or if it has not even been started?
  -- Do I handle that here or in the build status changed event? I think the
  -- answer is "do as much as possible here" because the events are ephemeral,
  -- but the state can be persisted to disk, so the process can continue after a
  -- restart.
  Just candidate -> proceedCandidate candidate state
  -- No current integration candidate, find the next one.
  Nothing -> case Pr.candidatePullRequests state of
    -- No pull requests eligible, do nothing.
    []     -> return state
    -- Found a new candidate, try to integrate it.
    pr : _ -> tryIntegratePullRequest pr state

-- TODO: Get rid of the tuple; just pass the ID and do the lookup with fromJust.
proceedCandidate :: (PullRequestId, PullRequest) -> ProjectState -> Action ProjectState
proceedCandidate (pullRequestId, pullRequest) state =
  case Pr.buildStatus pullRequest of
    BuildNotStarted -> error "integration candidate build should at least be pending"
    BuildPending    -> pure state
    BuildSucceeded  -> pushCandidate (pullRequestId, pullRequest) state
    BuildFailed     -> do
      -- If the build failed, this is no longer a candidate.
      leaveComment pullRequestId "The build failed."
      pure $ Pr.setIntegrationCandidate Nothing state

-- Given a pull request id, returns the name of the GitHub ref for that pull
-- request, so it can be fetched.
getPullRequestRef :: PullRequestId -> Branch
getPullRequestRef (PullRequestId n) = Branch $ format "refs/pull/{}/head" [n]

-- Integrates proposed changes from the pull request into the target branch.
-- The pull request must exist in the project.
tryIntegratePullRequest :: PullRequestId -> ProjectState -> Action ProjectState
tryIntegratePullRequest pr state =
  let
    PullRequestId prNumber = pr
    pullRequest  = fromJust $ Pr.lookupPullRequest pr state
    Username approvedBy = fromJust $ Pr.approvedBy pullRequest
    candidateSha = Pr.sha pullRequest
    candidateRef = getPullRequestRef pr
    candidate = (candidateRef, candidateSha)
    mergeMessage = format "Merge #{}\n\nApproved-by: {}" (prNumber, approvedBy)
  in do
    result <- tryIntegrate mergeMessage candidate
    case result of
      Nothing  -> do
        -- If integrating failed, perform no further actions but do set the
        -- state to conflicted.
        leaveComment pr "Failed to rebase, please rebase manually."
        pure $ Pr.setIntegrationStatus pr Conflicted state

      Just (Sha sha) -> do
        -- If it succeeded, update the integration candidate, and set the build
        -- to pending, as pushing should have triggered a build.
        leaveComment pr $ Text.concat ["Rebased as ", sha, ", waiting for CI …"]
        pure
          $ Pr.setIntegrationStatus pr (Integrated $ Sha sha)
          $ Pr.setBuildStatus pr BuildPending
          $ Pr.setIntegrationCandidate (Just pr)
          $ state

-- Pushes the integrated commits of the given candidate pull request to the
-- target branch. If the push fails, restarts the integration cycle for the
-- candidate.
-- TODO: Get rid of the tuple; just pass the ID and do the lookup with fromJust.
pushCandidate :: (PullRequestId, PullRequest) -> ProjectState -> Action ProjectState
pushCandidate (pullRequestId, pullRequest) state = do
  -- Look up the sha that will be pushed to the target branch. Also assert that
  -- the pull request has really been approved and built successfully. If it was
  -- not, there is a bug in the program.
  let approved  = isJust $ Pr.approvedBy pullRequest
      succeeded = Pr.buildStatus pullRequest == BuildSucceeded
      status    = Pr.integrationStatus pullRequest
      prBranch  = Pr.branch pullRequest
      newHead   = assert (approved && succeeded) $ case status of
        Integrated sha -> sha
        _              -> error "inconsistent state: build succeeded for non-integrated pull request"
  pushResult <- tryPromote prBranch newHead
  case pushResult of
    -- If the push worked, then this was the final stage of the pull
    -- request; reset the integration candidate.
    -- TODO: Leave a comment? And close the PR via the API.
    PushOk -> return $ Pr.setIntegrationCandidate Nothing state
    -- If something was pushed to the target branch while the candidate was
    -- being tested, try to integrate again and hope that next time the push
    -- succeeds.
    PushRejected -> tryIntegratePullRequest pullRequestId state

-- Keep doing a proceed step until the state doesn't change any more. For this
-- to work properly, it is essential that "proceed" does not have any side
-- effects if it does not change the state.
proceedUntilFixedPoint :: ProjectState -> Action ProjectState
proceedUntilFixedPoint state = do
  newState <- proceed state
  if newState == state
    then return state
    else proceedUntilFixedPoint newState

handleEvent
  :: TriggerConfiguration
  -> Event
  -> ProjectState
  -> Action ProjectState
handleEvent triggerConfig event state =
  handleEventInternal triggerConfig event state >>= proceedUntilFixedPoint
