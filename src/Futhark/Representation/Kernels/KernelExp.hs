{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ConstraintKinds #-}
-- | A representation of nested-parallel in-kernel per-workgroup
-- expressions.
module Futhark.Representation.Kernels.KernelExp
  ( KernelExp (..)
  , GroupStreamLambda(..)
  , typeCheckKernelExp
  )
  where

import Control.Applicative
import Data.Traversable hiding (mapM)
import Control.Monad
import Data.Monoid
import Data.Maybe
import qualified Data.HashSet as HS
import qualified Data.HashMap.Lazy as HM

import Prelude

import qualified Futhark.Analysis.Alias as Alias
import qualified Futhark.Analysis.Range as Range
import Futhark.Representation.Aliases
import Futhark.Representation.Ranges
import Futhark.Transform.Substitute
import Futhark.Transform.Rename
import Futhark.Optimise.Simplifier.Lore
import Futhark.Analysis.Usage
import Futhark.Analysis.Metrics
import Futhark.Util.Pretty
  ((<+>), (</>), ppr, commasep, Pretty, parens, text, apply, braces, annot, indent)
import qualified Futhark.TypeCheck as TC

data KernelExp lore = SplitArray StreamOrd SubExp SubExp SubExp SubExp [VName]
                    | SplitSpace StreamOrd SubExp SubExp SubExp SubExp
                    | Combine [(VName,SubExp)] [Type] (Body lore)
                    | GroupReduce SubExp
                      (Lambda lore) [(SubExp,VName)]
                    | GroupStream SubExp SubExp
                      (GroupStreamLambda lore) [SubExp] [VName]
                    deriving (Eq, Ord, Show)

data GroupStreamLambda lore = GroupStreamLambda
  { groupStreamChunkSize :: VName
  , groupStreamChunkOffset :: VName
  , groupStreamAccParams :: [LParam lore]
  , groupStreamArrParams :: [LParam lore]
  , groupStreamLambdaBody :: Body lore
  }

deriving instance Annotations lore => Eq (GroupStreamLambda lore)
deriving instance Annotations lore => Show (GroupStreamLambda lore)
deriving instance Annotations lore => Ord (GroupStreamLambda lore)

instance Attributes lore => IsOp (KernelExp lore) where
  safeOp _ = False

instance Attributes lore => TypedOp (KernelExp lore) where
  opType (SplitArray _ _ _ _ _ arrs) =
    traverse (fmap setRetType . lookupType) arrs
    where setRetType arr_t =
            let chunk_shape = Ext 0 : map Free (drop 1 $ arrayDims arr_t)
            in arr_t `setArrayShape` ExtShape chunk_shape
  opType SplitSpace{} =
    pure $ staticShapes [Prim int32]
  opType (Combine ispace ts _) =
    pure $ staticShapes $ map (`arrayOfShape` shape) ts
    where shape = Shape $ map snd ispace
  opType (GroupReduce _ lam _) =
    pure $ staticShapes $ lambdaReturnType lam
  opType (GroupStream _ _ lam _ _) =
    pure $ staticShapes $ map paramType $ groupStreamAccParams lam

instance Attributes lore => FreeIn (KernelExp lore) where
  freeIn (SplitArray _ w i num_is elems_per_thread vs) =
    freeIn [w, i, num_is, elems_per_thread] <> freeIn vs
  freeIn (SplitSpace _ w i num_is elems_per_thread) =
    freeIn [w, i, num_is, elems_per_thread]
  freeIn (Combine cspace ts body) =
    freeIn cspace <> freeIn ts <> freeInBody body
  freeIn (GroupReduce w lam input) =
    freeIn w <> freeInLambda lam <> freeIn input
  freeIn (GroupStream w maxchunk lam accs arrs) =
    freeIn w <> freeIn maxchunk <> freeIn lam <> freeIn accs <> freeIn arrs

instance Attributes lore => FreeIn (GroupStreamLambda lore) where
  freeIn (GroupStreamLambda chunk_size chunk_offset acc_params arr_params body) =
    freeInBody body `HS.difference` bound_here
    where bound_here = HS.fromList $
                       chunk_offset : chunk_size :
                       map paramName (acc_params ++ arr_params)

instance Ranged inner => RangedOp (KernelExp inner) where
  opRanges _ = repeat unknownRange

instance (Attributes lore, Aliased lore) => AliasedOp (KernelExp lore) where
  opAliases (SplitArray _ _ _ _ _ arrs) =
    map HS.singleton arrs
  opAliases SplitSpace{} =
    [mempty]
  opAliases Combine{} =
    [mempty]
  opAliases (GroupReduce _ lam _) =
    replicate (length (lambdaReturnType lam)) mempty
  opAliases (GroupStream _ _ lam _ _) =
    map (const mempty) $ groupStreamAccParams lam

  consumedInOp (GroupReduce _ _ input) =
    HS.fromList $ map snd input
  consumedInOp (GroupStream _ _ lam nes arrs) =
    HS.map consumedArray $ consumedInBody body
    where GroupStreamLambda _ _ acc_params arr_params body = lam
          consumedArray v = fromMaybe v $ subExpVar =<< lookup v params_to_arrs
          params_to_arrs = zip (map paramName $ acc_params ++ arr_params) $
                           nes ++ map Var arrs

  consumedInOp SplitArray{} = mempty
  consumedInOp SplitSpace{} = mempty
  consumedInOp Combine{} = mempty

instance Attributes lore => Substitute (KernelExp lore) where
  substituteNames subst (SplitArray o w i max_is elems_per_thread vs) =
    SplitArray o
    (substituteNames subst w)
    (substituteNames subst i)
    (substituteNames subst max_is)
    (substituteNames subst elems_per_thread)
    (substituteNames subst vs)
  substituteNames subst (SplitSpace o w i max_is elems_per_thread) =
    SplitSpace o
    (substituteNames subst w)
    (substituteNames subst i)
    (substituteNames subst max_is)
    (substituteNames subst elems_per_thread)
  substituteNames subst (Combine cspace ts v) =
    Combine (substituteNames subst cspace) ts (substituteNames subst v)
  substituteNames subst (GroupReduce w lam input) =
    GroupReduce (substituteNames subst w)
    (substituteNames subst lam) (substituteNames subst input)
  substituteNames subst (GroupStream w maxchunk lam accs arrs) =
    GroupStream
    (substituteNames subst w) (substituteNames subst maxchunk)
    (substituteNames subst lam)
    (substituteNames subst accs) (substituteNames subst arrs)

instance Attributes lore => Substitute (GroupStreamLambda lore) where
  substituteNames
    subst (GroupStreamLambda chunk_size chunk_offset acc_params arr_params body) =
    GroupStreamLambda
    (substituteNames subst chunk_size)
    (substituteNames subst chunk_offset)
    (substituteNames subst acc_params)
    (substituteNames subst arr_params)
    (substituteNames subst body)

instance (Attributes lore, Renameable lore) => Rename (KernelExp lore) where
  rename (SplitArray o w i num_is elems_per_thread vs) =
    SplitArray
    <$> pure o
    <*> rename w
    <*> rename i
    <*> rename num_is
    <*> rename elems_per_thread
    <*> rename vs
  rename (SplitSpace o w i num_is elems_per_thread) =
    SplitSpace
    <$> pure o
    <*> rename w
    <*> rename i
    <*> rename num_is
    <*> rename elems_per_thread
  rename (Combine cspace ts v) =
    Combine <$> rename cspace <*> rename ts <*> rename v
  rename (GroupReduce w lam input) =
    GroupReduce <$> rename w <*> rename lam <*> rename input
  rename (GroupStream w maxchunk lam accs arrs) =
    GroupStream <$> rename w <*> rename maxchunk <*>
    rename lam <*> rename accs <*> rename arrs

instance (Attributes lore, Renameable lore) => Rename (GroupStreamLambda lore) where
  rename (GroupStreamLambda chunk_size chunk_offset acc_params arr_params body) =
    bindingForRename (chunk_size : chunk_offset :
                       map paramName (acc_params++arr_params)) $
    GroupStreamLambda <$>
    rename chunk_size <*>
    rename chunk_offset <*>
    rename acc_params <*>
    rename arr_params <*>
    rename body

instance (Attributes lore,
          Attributes (Aliases lore),
          CanBeAliased (Op lore)) => CanBeAliased (KernelExp lore) where
  type OpWithAliases (KernelExp lore) = KernelExp (Aliases lore)

  addOpAliases (SplitArray o w i num_is elems_per_thread arrs) =
    SplitArray o w i num_is elems_per_thread arrs
  addOpAliases (SplitSpace o w i num_is elems_per_thread) =
    SplitSpace o w i num_is elems_per_thread
  addOpAliases (GroupReduce w lam input) =
    GroupReduce w (Alias.analyseLambda lam) input
  addOpAliases (GroupStream w maxchunk lam accs arrs) =
    GroupStream w maxchunk lam' accs arrs
    where lam' = analyseGroupStreamLambda lam
          analyseGroupStreamLambda (GroupStreamLambda chunk_size chunk_offset acc_params arr_params body) =
            GroupStreamLambda chunk_size chunk_offset acc_params arr_params $
            Alias.analyseBody body
  addOpAliases (Combine ispace ts body) =
    Combine ispace ts $ Alias.analyseBody body

  removeOpAliases (GroupReduce w lam input) =
    GroupReduce w (removeLambdaAliases lam) input
  removeOpAliases (GroupStream w maxchunk lam accs arrs) =
    GroupStream w maxchunk (removeGroupStreamLambdaAliases lam) accs arrs
    where removeGroupStreamLambdaAliases (GroupStreamLambda chunk_size chunk_offset acc_params arr_params body) =
            GroupStreamLambda chunk_size chunk_offset acc_params arr_params $
            removeBodyAliases body

  removeOpAliases (Combine ispace ts body) =
    Combine ispace ts $ removeBodyAliases body
  removeOpAliases (SplitArray o w i num_is elems_per_thread arrs) =
    SplitArray o w i num_is elems_per_thread arrs
  removeOpAliases (SplitSpace o w i num_is elems_per_thread) =
    SplitSpace o w i num_is elems_per_thread

instance (Attributes lore,
          Attributes (Ranges lore),
          CanBeRanged (Op lore)) => CanBeRanged (KernelExp lore) where
  type OpWithRanges (KernelExp lore) = KernelExp (Ranges lore)

  addOpRanges (SplitArray o w i num_is elems_per_thread arrs) =
    SplitArray o w i num_is elems_per_thread arrs
  addOpRanges (SplitSpace o w i num_is elems_per_thread) =
    SplitSpace o w i num_is elems_per_thread
  addOpRanges (GroupReduce w lam input) =
    GroupReduce w (Range.runRangeM $ Range.analyseLambda lam) input
  addOpRanges (Combine ispace ts body) =
    Combine ispace ts $ Range.runRangeM $ Range.analyseBody body
  addOpRanges (GroupStream w maxchunk lam accs arrs) =
    GroupStream w maxchunk lam' accs arrs
    where lam' = analyseGroupStreamLambda lam
          analyseGroupStreamLambda (GroupStreamLambda chunk_size chunk_offset acc_params arr_params body) =
            GroupStreamLambda chunk_size chunk_offset acc_params arr_params $
            Range.runRangeM $ Range.analyseBody body

  removeOpRanges (GroupReduce w lam input) =
    GroupReduce w (removeLambdaRanges lam) input
  removeOpRanges (GroupStream w maxchunk lam accs arrs) =
    GroupStream w maxchunk (removeGroupStreamLambdaRanges lam) accs arrs
    where removeGroupStreamLambdaRanges (GroupStreamLambda chunk_size chunk_offset acc_params arr_params body) =
            GroupStreamLambda chunk_size chunk_offset acc_params arr_params $
            removeBodyRanges body
  removeOpRanges (Combine ispace ts body) =
    Combine ispace ts $ removeBodyRanges body
  removeOpRanges (SplitArray o w i num_is elems_per_thread arrs) =
    SplitArray o w i num_is elems_per_thread arrs
  removeOpRanges (SplitSpace o w i num_is elems_per_thread) =
    SplitSpace o w i num_is elems_per_thread

instance (Attributes lore, CanBeWise (Op lore)) => CanBeWise (KernelExp lore) where
  type OpWithWisdom (KernelExp lore) = KernelExp (Wise lore)

  removeOpWisdom (GroupReduce w lam input) =
    GroupReduce w (removeLambdaWisdom lam) input
  removeOpWisdom (GroupStream w maxchunk lam accs arrs) =
    GroupStream w maxchunk (removeGroupStreamLambdaWisdom lam) accs arrs
    where removeGroupStreamLambdaWisdom
            (GroupStreamLambda chunk_size chunk_offset acc_params arr_params body) =
            GroupStreamLambda chunk_size chunk_offset acc_params arr_params $
            removeBodyWisdom body
  removeOpWisdom (Combine ispace ts body) =
    Combine ispace ts $ removeBodyWisdom body
  removeOpWisdom (SplitArray o w i num_is elems_per_thread arrs) =
    SplitArray o w i num_is elems_per_thread arrs
  removeOpWisdom (SplitSpace o w i num_is elems_per_thread) =
    SplitSpace o w i num_is elems_per_thread

instance (Attributes lore, Aliased lore, UsageInOp (Op lore)) => UsageInOp (KernelExp lore) where
  usageInOp _ = mempty

instance OpMetrics (Op lore) => OpMetrics (KernelExp lore) where
  opMetrics SplitArray{} = seen "SplitArray"
  opMetrics SplitSpace{} = seen "SplitSpace"
  opMetrics Combine{} = seen "Combine"
  opMetrics (GroupReduce _ lam _) = inside "GroupReduce" $ lambdaMetrics lam
  opMetrics (GroupStream _ _ lam _ _) =
    inside "GroupStream" $ groupStreamLambdaMetrics lam
    where groupStreamLambdaMetrics =
            bodyMetrics . groupStreamLambdaBody

typeCheckKernelExp :: TC.Checkable lore => KernelExp (Aliases lore) -> TC.TypeM lore ()
typeCheckKernelExp (SplitArray _ w i num_is elems_per_thread arrs) = do
  mapM_ (TC.require [Prim int32]) [w, i, num_is, elems_per_thread]
  void $ TC.checkSOACArrayArgs w arrs

typeCheckKernelExp (SplitSpace _ w i num_is elems_per_thread) =
  mapM_ (TC.require [Prim int32]) [w, i, num_is, elems_per_thread]

typeCheckKernelExp (Combine cspace ts body) = do
  mapM_ (TC.requireI [Prim int32]) is
  mapM_ TC.checkType ts
  mapM_ (TC.require [Prim int32]) ws
  TC.checkLambdaBody ts body
  where (is, ws) = unzip cspace

typeCheckKernelExp (GroupReduce w lam input) = do
  TC.require [Prim int32] w
  let (nes, arrs) = unzip input
      asArg t = (t, mempty)
  neargs <- mapM TC.checkArg nes
  arrargs <- TC.checkSOACArrayArgs w arrs
  TC.checkLambda lam $
    map asArg [Prim int32, Prim int32] ++
    map TC.noArgAliases (neargs ++ arrargs)

typeCheckKernelExp (GroupStream w maxchunk lam accs arrs) = do
  TC.require [Prim int32] w
  TC.require [Prim int32] maxchunk

  acc_args <- mapM (fmap TC.noArgAliases . TC.checkArg) accs
  arr_args <- TC.checkSOACArrayArgs w arrs

  checkGroupStreamLambda acc_args arr_args
  where GroupStreamLambda block_size _ acc_params arr_params body = lam
        checkGroupStreamLambda acc_args arr_args = do
          unless (map TC.argType acc_args == map paramType acc_params) $
            TC.bad $ TC.TypeError
            "checkGroupStreamLambda: wrong accumulator arguments."

          let arr_block_ts =
                map ((`arrayOfRow` Var block_size) . TC.argType) arr_args
          unless (map paramType arr_params == arr_block_ts) $
            TC.bad $ TC.TypeError
            "checkGroupStreamLambda: wrong array arguments."

          let acc_consumable =
                zip (map paramName acc_params) (map TC.argAliases acc_args)
              arr_consumable =
                zip (map paramName arr_params) (map TC.argAliases arr_args)
              consumable = acc_consumable ++ arr_consumable
          TC.binding (scopeOf lam) $ TC.consumeOnlyParams consumable $ do
            TC.checkLambdaParams acc_params
            TC.checkLambdaParams arr_params
            TC.checkLambdaBody (map TC.argType acc_args) body

instance LParamAttr lore1 ~ LParamAttr lore2 =>
         Scoped lore1 (GroupStreamLambda lore2) where
  scopeOf (GroupStreamLambda chunk_size chunk_offset acc_params arr_params _) =
    HM.insert chunk_size IndexInfo $
    HM.insert chunk_offset IndexInfo $
    scopeOfLParams (acc_params ++ arr_params)

instance PrettyLore lore => Pretty (KernelExp lore) where
  ppr (SplitArray o w i num_is elems_per_thread arrs) =
    text ("splitArray" <> suff) <>
    parens (commasep $ ppr w : ppr elems_per_thread :
            (ppr i <+> text "<" <+> ppr num_is) :
            map ppr arrs)
    where suff = case o of InOrder -> ""
                           Disorder -> "Unordered"
  ppr (SplitSpace o w i num_is elems_per_thread) =
    text ("splitSpace" <> suff) <>
    parens (commasep [ppr w, ppr elems_per_thread,
                      ppr i <+> text "<" <+> ppr num_is])
    where suff = case o of InOrder -> ""
                           Disorder -> "Unordered"
  ppr (Combine cspace ts body) =
    text "combine" <> apply (map f cspace ++ [apply (map ppr ts)]) <+> text "{" </>
    indent 2 (ppr body) </>
    text "}"
    where f (i, w) = ppr i <+> text "<" <+> ppr w
  ppr (GroupReduce w lam input) =
    text "reduce" <> parens (commasep [ppr w,
                                       ppr lam,
                                       braces (commasep $ map ppr nes),
                                       commasep $ map ppr els])
    where (nes,els) = unzip input
  ppr (GroupStream w maxchunk lam accs arrs) =
    text "stream" <>
    parens (commasep [ppr w,
                      ppr maxchunk,
                      ppr lam,
                      braces (commasep $ map ppr accs),
                      commasep $ map ppr arrs])

instance PrettyLore lore => Pretty (GroupStreamLambda lore) where
  ppr (GroupStreamLambda block_size block_offset acc_params arr_params body) =
    annot (mapMaybe ppAnnot params) $
    text "fn" <+>
    parens (commasep (block_size' : block_offset' : map ppr params)) <+>
    text "=>" </> indent 2 (ppr body)
    where params = acc_params ++ arr_params
          block_size' = text "int" <+> ppr block_size
          block_offset' = text "int" <+> ppr block_offset
