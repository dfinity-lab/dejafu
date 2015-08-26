{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes                #-}

-- | Common types and utility functions for deterministic execution of
-- 'MonadConc' implementations.
module Test.DejaFu.Deterministic.Internal.Common where

import Control.DeepSeq (NFData(..))
import Control.Exception (Exception, MaskingState(..), SomeException(..))
import Control.Monad.Cont (Cont)
import Data.List.Extra
import Test.DejaFu.Internal
import Test.DejaFu.STM (CTVarId)

--------------------------------------------------------------------------------
-- * The @Conc@ Monad

-- | The underlying monad is based on continuations over Actions.
type M n r s a = Cont (Action n r s) a

-- | CVars are represented as a unique numeric identifier, and a
-- reference containing a Maybe value.
type V r a = (CVarId, r (Maybe a))

-- | CRefs are represented as a unique numeric identifier, and a
-- reference containing a value.
type R r a = (CRefId, r a)

-- | Dict of methods for implementations to override.
type Fixed n r s = Ref n r (Cont (Action n r s))

--------------------------------------------------------------------------------
-- * Primitive Actions

-- | Scheduling is done in terms of a trace of 'Action's. Blocking can
-- only occur as a result of an action, and they cover (most of) the
-- primitives of the concurrency. 'spawn' is absent as it is
-- implemented in terms of 'newEmptyCVar', 'fork', and 'putCVar'.
data Action n r s =
    AFork ((forall b. M n r s b -> M n r s b) -> Action n r s) (ThreadId -> Action n r s)
  | AMyTId (ThreadId -> Action n r s)
  | forall a. APut     (V r a) a (Action n r s)
  | forall a. ATryPut  (V r a) a (Bool -> Action n r s)
  | forall a. AGet     (V r a) (a -> Action n r s)
  | forall a. ATake    (V r a) (a -> Action n r s)
  | forall a. ATryTake (V r a) (Maybe a -> Action n r s)
  | forall a. AReadRef (R r a) (a -> Action n r s)
  | forall a b. AModRef  (R r a) (a -> (a, b)) (b -> Action n r s)
  | forall a. ANoTest  (M n r s a) (a -> Action n r s)
  | forall a. AAtom    (s n r a) (a -> Action n r s)
  | ANew  (CVarId -> n (Action n r s))
  | ANewRef (CRefId -> n (Action n r s))
  | ALift (n (Action n r s))
  | AThrow SomeException
  | AThrowTo ThreadId SomeException (Action n r s)
  | forall a e. Exception e => ACatching (e -> M n r s a) (M n r s a) (a -> Action n r s)
  | APopCatching (Action n r s)
  | forall a. AMasking MaskingState ((forall b. M n r s b -> M n r s b) -> M n r s a) (a -> Action n r s)
  | AResetMask Bool Bool MaskingState (Action n r s)
  | AKnowsAbout (Either CVarId CTVarId) (Action n r s)
  | AForgets (Either CVarId CTVarId) (Action n r s)
  | AAllKnown (Action n r s)
  | AStop

--------------------------------------------------------------------------------
-- * Identifiers

-- | Every live thread has a unique identitifer.
type ThreadId = Int

-- | Every 'CVar' has a unique identifier.
type CVarId = Int

-- | Every 'CRef' has a unique identifier.
type CRefId = Int

-- | The number of ID parameters was getting a bit unwieldy, so this
-- hides them all away.
data IdSource = Id { _nextCRId :: CRefId, _nextCVId :: CVarId, _nextCTVId :: CTVarId, _nextTId :: ThreadId }

-- | Get the next free 'CRefId'.
nextCRId :: IdSource -> (IdSource, CRefId)
nextCRId idsource = let newid = _nextCRId idsource + 1 in (idsource { _nextCRId = newid }, newid)

-- | Get the next free 'CVarId'.
nextCVId :: IdSource -> (IdSource, CVarId)
nextCVId idsource = let newid = _nextCVId idsource + 1 in (idsource { _nextCVId = newid }, newid)

-- | Get the next free 'CTVarId'.
nextCTVId :: IdSource -> (IdSource, CTVarId)
nextCTVId idsource = let newid = _nextCTVId idsource + 1 in (idsource { _nextCTVId = newid }, newid)

-- | Get the next free 'ThreadId'.
nextTId :: IdSource -> (IdSource, ThreadId)
nextTId idsource = let newid = _nextTId idsource + 1 in (idsource { _nextTId = newid }, newid)

-- | The initial ID source.
initialIdSource :: IdSource
initialIdSource = Id 0 0 0 0

--------------------------------------------------------------------------------
-- * Scheduling & Traces

-- | A @Scheduler@ maintains some internal state, @s@, takes the
-- 'ThreadId' of the last thread scheduled, or 'Nothing' if this is
-- the first decision, and the list of runnable threads along with
-- what each will do in the next steps (as far as can be
-- determined). It produces a 'ThreadId' to schedule, and a new state.
--
-- __Note:__ In order to prevent computation from hanging, the runtime
-- will assume that a deadlock situation has arisen if the scheduler
-- attempts to (a) schedule a blocked thread, or (b) schedule a
-- nonexistent thread. In either of those cases, the computation will
-- be halted.
type Scheduler s = s -> Maybe (ThreadId, ThreadAction) -> NonEmpty (ThreadId, NonEmpty Lookahead) -> (ThreadId, s)

-- | One of the outputs of the runner is a @Trace@, which is a log of
-- decisions made, alternative decisions (including what action would
-- have been performed had that decision been taken), and the action a
-- thread took in its step.
type Trace = [(Decision, [(Decision, Lookahead)], ThreadAction)]

-- | Like a 'Trace', but gives more lookahead (where possible) for
-- alternative decisions.
type Trace' = [(Decision, [(Decision, NonEmpty Lookahead)], ThreadAction)]

-- | Throw away information from a 'Trace'' to get just a 'Trace'.
toTrace :: Trace' -> Trace
toTrace = map go where
  go (dec, alters, act) = (dec, map (\(d, a:|_) -> (d, a)) alters, act)

-- | Pretty-print a trace.
showTrace :: Trace -> String
showTrace = trace "" 0 where
  trace prefix num ((Start tid,_,_):ds)    = thread prefix num ++ trace ("S" ++ show tid) 1 ds
  trace prefix num ((SwitchTo tid,_,_):ds) = thread prefix num ++ trace ("P" ++ show tid) 1 ds
  trace prefix num ((Continue,_,_):ds)     = trace prefix (num + 1) ds
  trace prefix num []                      = thread prefix num

  thread prefix num = prefix ++ replicate num '-'

-- | Scheduling decisions are based on the state of the running
-- program, and so we can capture some of that state in recording what
-- specific decision we made.
data Decision =
    Start ThreadId
  -- ^ Start a new thread, because the last was blocked (or it's the
  -- start of computation).
  | Continue
  -- ^ Continue running the last thread for another step.
  | SwitchTo ThreadId
  -- ^ Pre-empt the running thread, and switch to another.
  deriving (Eq, Show)

instance NFData Decision where
  rnf (Start    tid) = rnf tid
  rnf (SwitchTo tid) = rnf tid
  rnf Continue = ()

-- | All the actions that a thread can perform.
data ThreadAction =
    Fork ThreadId
  -- ^ Start a new thread.
  | MyThreadId
  -- ^ Get the 'ThreadId' of the current thread.
  | New CVarId
  -- ^ Create a new 'CVar'.
  | Put CVarId [ThreadId]
  -- ^ Put into a 'CVar', possibly waking up some threads.
  | BlockedPut CVarId
  -- ^ Get blocked on a put.
  | TryPut CVarId Bool [ThreadId]
  -- ^ Try to put into a 'CVar', possibly waking up some threads.
  | Read CVarId
  -- ^ Read from a 'CVar'.
  | BlockedRead CVarId
  -- ^ Get blocked on a read.
  | Take CVarId [ThreadId]
  -- ^ Take from a 'CVar', possibly waking up some threads.
  | BlockedTake CVarId
  -- ^ Get blocked on a take.
  | TryTake CVarId Bool [ThreadId]
  -- ^ Try to take from a 'CVar', possibly waking up some threads.
  | NewRef CRefId
  -- ^ Create a new 'CRef'.
  | ReadRef CRefId
  -- ^ Read from a 'CRef'.
  | ModRef CRefId
  -- ^ Modify a 'CRef'.
  | STM [ThreadId]
  -- ^ An STM transaction was executed, possibly waking up some
  -- threads.
  | FreshSTM
  -- ^ An STM transaction was executed, and all it did was create and
  -- write to new 'CTVar's, no existing 'CTVar's were touched.
  | BlockedSTM
  -- ^ Got blocked in an STM transaction.
  | Catching
  -- ^ Register a new exception handler
  | PopCatching
  -- ^ Pop the innermost exception handler from the stack.
  | Throw
  -- ^ Throw an exception.
  | ThrowTo ThreadId
  -- ^ Throw an exception to a thread.
  | BlockedThrowTo ThreadId
  -- ^ Get blocked on a 'throwTo'.
  | Killed
  -- ^ Killed by an uncaught exception.
  | SetMasking Bool MaskingState
  -- ^ Set the masking state. If 'True', this is being used to set the
  -- masking state to the original state in the argument passed to a
  -- 'mask'ed function.
  | ResetMasking Bool MaskingState
  -- ^ Return to an earlier masking state.  If 'True', this is being
  -- used to return to the state of the masked block in the argument
  -- passed to a 'mask'ed function.
  | Lift
  -- ^ Lift an action from the underlying monad. Note that the
  -- penultimate action in a trace will always be a @Lift@, this is an
  -- artefact of how the runner works.
  | NoTest
  -- ^ A computation annotated with '_concNoTest' was executed in a
  -- single step.
  | KnowsAbout
  -- ^ A '_concKnowsAbout' annotation was processed.
  | Forgets
  -- ^ A '_concForgets' annotation was processed.
  | AllKnown
  -- ^ A '_concALlKnown' annotation was processed.
  | Stop
  -- ^ Cease execution and terminate.
  deriving (Eq, Show)

instance NFData ThreadAction where
  rnf (TryTake c b tids) = rnf (c, b, tids)
  rnf (TryPut  c b tids) = rnf (c, b, tids)
  rnf (SetMasking   b m) = m `seq` b `seq` ()
  rnf (ResetMasking b m) = m `seq` b `seq` ()
  rnf (BlockedRead c) = rnf c
  rnf (BlockedTake c) = rnf c
  rnf (BlockedPut  c) = rnf c
  rnf (ThrowTo tid) = rnf tid
  rnf (Take c tids) = rnf (c, tids)
  rnf (Put  c tids) = rnf (c, tids)
  rnf (STM  tids) = rnf tids
  rnf (Fork tid)  = rnf tid
  rnf (New  c) = rnf c
  rnf (Read c) = rnf c
  rnf ta = ta `seq` ()

-- | A one-step look-ahead at what a thread will do next.
data Lookahead =
    WillFork
  -- ^ Will start a new thread.
  | WillMyThreadId
  -- ^ Will get the 'ThreadId'.
  | WillNew
  -- ^ Will create a new 'CVar'.
  | WillPut CVarId
  -- ^ Will put into a 'CVar', possibly waking up some threads.
  | WillTryPut CVarId
  -- ^ Will try to put into a 'CVar', possibly waking up some threads.
  | WillRead CVarId
  -- ^ Will read from a 'CVar'.
  | WillTake CVarId
  -- ^ Will take from a 'CVar', possibly waking up some threads.
  | WillTryTake CVarId
  -- ^ Will try to take from a 'CVar', possibly waking up some threads.
  | WillNewRef
  -- ^ Will create a new 'CRef'.
  | WillReadRef CRefId
  -- ^ Will read from a 'CRef'.
  | WillModRef CRefId
  -- ^ Will modify a 'CRef'.
  | WillSTM
  -- ^ Will execute an STM transaction, possibly waking up some
  -- threads.
  | WillCatching
  -- ^ Will register a new exception handler
  | WillPopCatching
  -- ^ Will pop the innermost exception handler from the stack.
  | WillThrow
  -- ^ Will throw an exception.
  | WillThrowTo ThreadId
  -- ^ Will throw an exception to a thread.
  | WillSetMasking Bool MaskingState
  -- ^ Will set the masking state. If 'True', this is being used to
  -- set the masking state to the original state in the argument
  -- passed to a 'mask'ed function.
  | WillResetMasking Bool MaskingState
  -- ^ Will return to an earlier masking state.  If 'True', this is
  -- being used to return to the state of the masked block in the
  -- argument passed to a 'mask'ed function.
  | WillLift
  -- ^ Will lift an action from the underlying monad. Note that the
  -- penultimate action in a trace will always be a @Lift@, this is an
  -- artefact of how the runner works.
  | WillNoTest
  -- ^ Will execute a computation annotated with '_concNoTest' in a
  -- single step.
  | WillKnowsAbout
  -- ^ Will process a '_concKnowsAbout' annotation.
  | WillForgets
  -- ^ Will process a '_concForgets' annotation.
  | WillAllKnown
  -- ^ Will process a '_concALlKnown' annotation.
  | WillStop
  -- ^ Will cease execution and terminate.
  deriving (Eq, Show)

instance NFData Lookahead where
  rnf (WillSetMasking   b ms) = b `seq` ms `seq` ()
  rnf (WillResetMasking b ms) = b `seq` ms `seq` ()
  rnf (WillPut     c) = rnf c
  rnf (WillTryPut  c) = rnf c
  rnf (WillRead    c) = rnf c
  rnf (WillTake    c) = rnf c
  rnf (WillTryTake c) = rnf c
  rnf (WillReadRef c) = rnf c
  rnf (WillModRef  c) = rnf c
  rnf ta = ta `seq` ()

--------------------------------------------------------------------------------
-- * Failures

-- | An indication of how a concurrent computation failed.
data Failure =
    InternalError
  -- ^ Will be raised if the scheduler does something bad. This should
  -- never arise unless you write your own, faulty, scheduler! If it
  -- does, please file a bug report.
  | Deadlock
  -- ^ The computation became blocked indefinitely on @CVar@s.
  | STMDeadlock
  -- ^ The computation became blocked indefinitely on @CTVar@s.
  | UncaughtException
  -- ^ An uncaught exception bubbled to the top of the computation.
  | FailureInNoTest
  -- ^ A computation annotated with '_concNoTest' produced a failure,
  -- rather than a result.
  deriving (Eq, Show)

instance NFData Failure where
  rnf f = f `seq` () -- WHNF == NF
