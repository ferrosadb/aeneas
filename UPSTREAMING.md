# Upstreaming notes — memory pathology of the symbolic interpreter

Status: **not ready to submit.** This records what the work on
`fix/memory-pathology` fixes, what evidence backs each claim, what a maintainer
would have to be told before any of it is sent upstream, and what would count as
proving it is worth upstreaming at all. No pull request has been opened anywhere,
including the fork.

Nine branches are listed in section 6. Each builds and passes
`dune build @runtest` on the base it names, and each was checked against the
translation corpus for unintended output changes. One branch that did **not**
survive that check was withdrawn; it is in section 3, and it is the reason the
corpus check exists in this document.

---

## 1. The problem, in one paragraph

Translating a large Rust crate through the symbolic interpreter consumes memory in
proportion to the number of *paths* it keeps, and a path holds a whole evaluation
environment. On one generated 22 MiB LLBC input, a single function arrives from
MIR as 112,769 statements of which 92% are cleanup-ladder `StorageDead`s, and the
interpreter expands that body to 8,230 contexts in one statement list. 96% of the
retained contexts (938,547 of 979,978) are paths that have already finished — they
are carried so their result can be reported and are evaluated nowhere. The run
dies at a 4 GiB ceiling in the synthesis phase, before it emits anything.
Measured trajectory at that ceiling: `loop-break-ctx` t=147.8 s live 1,897 MiB;
`loop-synthesize` entry t=885 s live 234 MiB (collected down); killed t=983 s at
3,841 MiB, ramping ~40 MiB/s.

The series attacks the two ends that are safe to attack separately — what one path
costs (sharing) and how many paths exist (the join decision) — plus three smaller
leaks where a computation retains what nobody reads. **It does not make the input
translate**; section 5 says why, and what would.

## 2. Units

### 00 — describe the measured inputs generically (prerequisite hygiene)

`upstream/00-generic-crate-names`. Comments, one test's sample names and one local
design note named the specific crates the measurements were taken on. Renamed to
what matters — the shape and size of the input. One test constructs a name and
expects it back, so it is renamed on both sides; everything else is comment and
prose. **No behaviour change.** This exists so that every later branch contains no
crate names, and it is the base of all of them.

### 01 — parse a backend name containing a digit (test runner)

`upstream/01-test-runner-skip-regex`. 1 file, +1/−1.

The per-backend comment syntax is `[backend,...]` and one backend is named `hol4`;
the parser accepted letters only, so `[hol4] skip` was reported as an unparseable
comment and the run aborted. Before: `Fatal error: exception Failure("Unrecognized
special comment: `[hol4] skip`")`. After: the other three backends run and the
fourth is not invoked. One character, verified both ways on a probe test.

### 02 — skip statements whose evaluation cannot change the context

`upstream/02-skip-noop-statements`. 2 files, +73/−18.

MIR cleanup ladders make 92% of a generated body `StorageDead` on locals that
already hold `Bottom`. Each still paid for a context snapshot and a symbolic-value
expansion. The change skips `StorageLive`, `Nop`, `PlaceMention`, `Drop` when drops
are already modelled as no-ops, and `StorageDead` for a local whose value is
`Bottom` or unbound.

*Evidence.* Statement evaluations **6.5× down** (486k → 75k) and
time-to-memory-ceiling **~40% down** on the input above.

*Risk.* None to generated output, and this is the claim to test rather than trust:
a skipped statement must be one whose snapshot repeats the previous one, and a
repeated snapshot contributes no symbolic place. Corpus output is byte-identical
with and without the change (checked by diffing a 19-test run; also checked
directly on three tests before the change was committed).

### 03 — bound the retained fixed-point trace

`upstream/03-bounded-trace-ring`. 4 files, +170/−3.

The loop fixed-point search appended every joined context to a list whose only
consumer is a lazily printed trace; with tracing off the list was still built, so
the search's memory grew with its iteration count rather than with the size of the
loop. A small `Trace_ring` keeps the newest few values instead. `Test_trace_ring`
pins the contract: oldest dropped at capacity, order preserved on reading,
retention independent of the number of pushes.

*Risk.* The diagnostic now shows the last steps of a search rather than all of
them — that is the point, but it is a behaviour change for whoever reads the trace.

### 04 — share the unchanged parts of an environment across rewrites

`upstream/04-share-context-rewrites`. 7 files, +557/−97.

The synthesis keeps one evaluation context per symbolic statement, by
construction. That is affordable only if a context costs the part of the
environment that differs from the one it was derived from; the environment-wide
rewrites rebuilt every element, so every retained context held a full copy.

*Risk / approximation.* Sharing is decided by **shallow** equality — field and
pointer identity, never a deep comparison of values, which carry continuations and
would cost as much as the copy. A rewrite that rebuilds an abstraction in a way the
check cannot see keeps its copy: a missed sharing opportunity, never a wrong
result. All values involved are immutable, so sharing is not observable.
`Test_ctx_sharing` pins that the memory a rewrite retains does not scale with the
size of the environment.

### 05 — share the environment across forks, not just across rewrites

`upstream/05-share-across-forks`. 3 files, +168/−3.

A branch point substitutes the scrutinee's value into the context each arm starts
from, and that substitution went through a whole-context map visitor that rebuilt
every element whether it mentions the substituted value or not.

*Evidence.* One fork retains **594 words** on average, where it used to retain a
whole-environment rebuild (that environment is 370 elements, 215,778 words). The
retained cost of one more path in the widest statement list fell **17,108 →
14,769 words**. The test pins it: forking a 128-element environment used to retain
7,939 words on top of the parent's 19,462, and the retained cost must stop scaling
with the environment to pass.

*Risk.* Same shallow-equality approximation as 04. Also measured, and not enough:
of those 14,769 words, 14,537 are the environment-only marginal — what a path
costs is now the state it builds *after* it forks. Four thousand and ninety-five
contexts already cost 738 MiB above the first one.

### 06 — decide a switch join from what its branches ended in

`upstream/06-join-decision`. 5 files, +196/−56.

Whether to join a switch's contexts was decided by scanning the branch sub-blocks
for a `break`, `continue` or `return` anywhere below them. A block's tail is where
the *enclosing loop's* own `break` lives, so in a body that loops or returns the
scan answers "can leave" almost everywhere and no join is ever attempted. The
decision now comes from the results: two or more contexts that ended in `Unit` go
on to the rest of the block and are worth merging; a finished path cannot be merged
with anything. The three copies of the same try/with that guarded the join become
one helper, and the now-unused scan is removed.

*Evidence.* On the input above the scan declined to join at **16,476 of 16,476**
branch points of the function that runs out of memory (`joined_n=0`, `failed_n=0`,
`skipped_n=24,694`), and the widest statement list held 8,192 contexts of which one
continued (`w=8192 units=1 exits=8191 arms=[8191,1]`).

*Risk / what it does not do.* It does not make a branch point with *both* finished
and continuing paths joinable. That is structural, not cautious: a join is a `Let`
over the branch expression and the symbolic AST forbids `break`, `continue` and
`return` in a bound expression (`translate_let` sets those builders to `None`).
Merging the staying branches needs each arm to be handed its own continuation — a
change to `Cps.stl_cm_fun` and all its callers — which is **not in this series**. On
this input the change therefore does not move the 8,230-context figure; what it
does is make the decision correct and measurable. It *can* change generated output
in principle, so it was checked against the corpus: no change on the 19-test set
(section 4). `Test_join_width` pins the arithmetic of the decision and of the width
it leaves, including the combination that is deliberately not joined.

### 07 — treat a function item's own regions as its own

`upstream/07-fn-item-regions`. 8 files, +322/−63.

A return-position `impl Trait` is translated at the concrete type it resolves to,
and for an iterator over borrowed items that type mentions a function item:
`Map<Iter<'a, String>, for<'b> String::as_str<'b>>`. The second argument binds a
region of its own and instantiates it at every call; it is a zero-sized type and
borrows nothing. The translator read those regions as regions of the enclosing
signature: the signature check and the region hierarchy asserted there were none
and reported "Unimplemented", the free-region collector and the retyability check
raised, the backward translation refused the type, and the borrows interpreter had
no rule for the union of two uses of the same item. A function returning an
iterator over borrowed items — an ordinary shape — could not be translated at all.

The item's regions are now read as the item's own: the collector skips regions it
binds, the pure encoding erases them, and two uses of the same item are unioned by
their type arguments alone. What survives of the item is its identity and its type
arguments, which is what a value of it is.

*Evidence.* `tests/src/iter-return-borrowed-str.rs` is rejected without the change
— **five errors**, three signatures "Unimplemented" and the item's `FnMut`/`FnOnce`
impls reporting "found an occurrence of a lifetime constraint relating a
higher-ranked lifetime to a free lifetime", leaving a module with none of the
bodies — and accepted with it.

*Risk, and what a maintainer should confirm.* A bound region reaching the
free-region collector is no longer an inconsistency, so the region test now pins
that case as a **skip** next to a `Lub` region, which stays an error. That
loosening is the substance of the change and deserves to be reviewed as such
rather than as a bug fix. The committed Lean output is what this base emits;
regenerate rather than merge it if the surrounding backend has moved.

*One thing that has to be ported.* The unit's test change lands in
`src/Test_ty_regions.ml`, which exists on the fork and **not** upstream: it pins
the region-hierarchy cases the fork already collects. Before submission that
assertion has to move to whichever file upstream keeps those cases in, or be
dropped and replaced by the new `iter-return-borrowed-str` test, which is
self-contained.

### 08 — model the `Iterator` dictionary's provided methods (Lean backend)

`upstream/08-lean-iterator-models`, 2 commits. 12 files, +2009/−256.

Two commits, one subject: the four provided methods a crate actually calls that the
model did not carry.

* `Iterator::count` — a call through a generic `I: Iterator` is a projection of the
  dictionary, so the structure needed the field; on a concrete iterator the call
  names the implementation's own override, which for slices exists. Modelled once
  as the trait's loop over `next`, taking the number of steps as *fuel* (`count`
  does not terminate on an infinite iterator), with `Iterator.count.loop`,
  a field default, `count.trait_default`, and `loop_zero`/`loop_succ` proofs;
  `#guard` tests in `SliceIter.lean` pin the value for empty, single-element and
  many-element slices, a partly consumed iterator, a range, and a dictionary that
  keeps the default.
* `map`, `filter`, `chain`, `collect`, `find` — `Chain` and `Filter` structures
  beside `Map`/`Rev` with their `next` models and `impl_def`s; five new `Iterator`
  fields each with a default, so no existing dictionary changes; a
  `SimpleIterator` view with a `Coe` from the full dictionary (`collect` needs
  `IntoIterator<Self, Item, Self>`, whose blanket instance mentions `Iterator`
  again, so the field cannot be typed against the structure it is a field of); and
  `chainBody`/`mapBody`/`filterBody`/`findBody` split from the `trait_default`
  entry points, because `impl_def` can unfold a self-reference through a helper
  that is not itself a `trait_default` and cannot through one.

`src/extract/ExtractBuiltinLean.ml` is the regenerated model table
(`lake exe extract` then `ocamlformat`); most of that diff is line-number churn —
read the added entries, not the diff size. `tests/src/iter_adaptor_fields.rs` pins
both shapes for all five methods, including a crate-defined iterator whose
`impl Iterator` literal must carry every field. It is Lean-only, which is why the
test-runner parser fix (01) is in the series; the two units are otherwise
independent.

*Risk.* A model extension is only as good as the model: an adapter the model does
not describe is still emitted as an opaque stub. **The Lean side was verified.**
`lake build Aeneas` in `backends/lean` elaborates the whole library on this branch
(1795 jobs, exit 0) against the pinned Mathlib olean cache, whose `packages` tree
was symlinked in so no dependency was rebuilt. The `#guard` tests in
`SliceIter.lean` are part of that elaboration, so a wrong `count` value or a
`map`/`filter`/`chain`/`collect`/`find` body that does not typecheck fails the
build. The build reports no errors and no `sorry`; it does report two
unused-variable warnings, `Iter.lean:298` and `Iter.lean:305`, where a `fun {P}` /
`fun {B}` restates an implicit binder that the body then takes from the context —
cosmetic, and left alone here so the model matches what the branch emits. Also
verified here: `dune build @runtest @fmt` is green, and every fixture this unit
touches is reproduced by the translator on this base (including regenerating
`Closures.lean`, which loses the `Iterator::map` stub it used to emit).

Of the six Lean fixtures this unit regenerates or adds, five elaborate against the
rebuilt library with only `sorry` warnings: `IterAdaptorFields` (one `sorry`),
`IteratorCount`, `Closures`, `Issue1043IteratorMethods` and
`Issue1207ClosureSignatureRegions`. `tests/lean/IterReturnBorrowedStr.lean` does
not: `P.Insts.CoreOpsFunctionFnOnceTupleShared0StringShared0Str.call_once` is
emitted as `String → Result Str → String → Result Str` where the `FnOnce` record
wants `(String → Result Str) → String → Result Str`, and `call_mut` fails the same
way. That is the translator's stub for a function item's `FnOnce`/`FnMut` impl
carrying the closure's result type as an extra argument; **the same two errors
reproduce on 07 with this unit's fixture replaced by 07's**, so the model extension
neither causes nor fixes it. It is left as a known limitation rather than fixed
here.

## 3. Not upstream material — kept local, or withdrawn

These stay on `fix/memory-pathology` (the working branch) and in **no** unit. They
are recorded so nobody re-runs them.

* **`Diagnose` phase sampling to a file** (`src/Diagnose.ml` and the phase markers
  in `Translate.ml`, `InterpLoops*.ml`, `InterpStatements.ml`) — the tool that
  produced every number in this document. A translator killed at a memory ceiling
  receives `SIGKILL`: no handler runs and nothing on stderr is guaranteed to have
  been flushed, which is exactly the run whose evidence matters. Samples go to a
  file named by an environment variable, one line per sample, opened and closed per
  write, carrying phase, declaration in flight, `live_words`/`heap_words`/
  `top_heap_words`, statements evaluated, and the shape of the evaluation context.
  It is ~400 lines of plumbing whose only consumer is a person reading a log: offered,
  not submitted. Its tests (`Test_mem_report`, `Test_diagnose`) stay with it.
* **Join diagnostics** ("why was this branch point not joined", the width of each
  statement list, how many retained contexts are finished paths). This is the
  evidence for unit 06 and it is why unit 06 is smaller upstream than it is on the
  working branch: the sampling hooks were stripped from the packaged commit so
  that a reviewer is not asked to accept a diagnostics module in order to review a
  twenty-line decision change.
* **`PrePasses` tail-inlining (`remove_useless_joins`)** — another lane's
  experiment: do not move the block tail into every branch when the tail can end a
  path. Sound and pinned by a test but **measurably insufficient**: the prepassed
  body drops from 3,196 to 3,022 statements and `paths=8230` is unchanged. Kept on
  a local branch; the test does not compile (`Meta.file_id` vs `int`).
* **Environment-variable probes** (`AENEAS_PATH_PROBE`, `AENEAS_PASS_PROBE`,
  `AENEAS_PREPASS_PROBE`, `AENEAS_NO_USELESS_JOINS`) — temporary; folded into the
  same local branch.

**Withdrawn after verification: trace-less evaluation.** A unit that scopes trace
composition through a domain-local flag so that a discarded trace retains nothing
(and so that the loop-body evaluations which only want the contexts do not build a
per-statement chain of closures) was packaged and then withdrawn: **the corpus
catches it.** `tests/src/loops.rs` fails inside the fixed-point search of
`issue400_1`, at a switch whose branch-expression builder applies a continuation
that was built under the "nobody applies this" assumption — `Cps.compose_trace`
returns a continuation that raises `internal_error` when the region is not traced,
and `eval_switch_raw` applies it. `dune build @runtest` does not exercise the
corpus, so the defect is invisible there, and the reasoning in that commit
("callers that discard the trace never apply it") is wrong for any switch inside a
discarded-trace region. It stays on the working branch. Fixing it means deciding
what a discard region is allowed to apply, which is a design question, not
packaging.

## 4. What a reviewer should run

```sh
# unit suite — the gate every branch in section 6 passed
cd src && dune build @runtest @fmt ./main.exe -j 2

# corpus — the fixtures must be reproduced byte for byte
cd "$REPO"
charon=./charon/bin/charon ; aeneas=./src/_build/default/main.exe
./tests/test_runner/_build/default/run_test.exe $charon $aeneas ./tests/llbc tests/src/<test>.rs
git status --short tests      # must be empty
```

The corpus sample used for every branch in section 6 is: `loops`, `loops-nested`,
`loops-issues`, `loops-rec`, `loops-sequences`, `loops-adts`, `loops-nested-rec`,
`issue-1206-loop-break`, `issue-1140-global-loop`, `issue-270-loop-list`,
`issue-789-loop-ctx-match`, `issue-1436-loop-generics`, `nested-loop-exits`,
`switch_test`, `loop_shared_loan_in_join`, `issue-134-loop-shared-borrows`,
`loops-borrow-check-negative`, `issue-1260-eliminate-shared-loans`,
`issue-1043-iterator-methods`.

Baseline: `upstream/00`, which reproduces every fixture in that sample exactly.
`issue-400` exits non-zero on the baseline as well and is excluded from the
comparison for that reason; the withdrawn trace-less unit is what made it worth
running `issue-400` too.

Result per unit, all measured against that baseline: **no fixture changed** — 01,
02, 03, 04, 05, 06, 07 and 08 each reproduce the corpus sample byte for byte. For
08 the two iterator tests and `Closures.lean` are additionally regenerated to what
this base emits.

The Lean model unit (08) additionally needs `lake build Aeneas` in `backends/lean`.
That was run on this branch with a pinned Mathlib olean cache symlinked at
`.lake/packages`, so no dependency target is built: 1795 jobs, exit 0, no errors,
no `sorry`, and the `#guard` tests in `Aeneas/Std/SliceIter.lean` elaborate as part
of it. Five of the six fixtures the unit regenerates then elaborate with
`lake env lean <fixture>` (only `sorry` warnings); `IterReturnBorrowedStr.lean`
fails on a pre-existing `FnOnce`/`FnMut` stub and is described in section 2. The
two unused-variable warnings the library build emits are described there too.

## 5. What "valuable" would look like

Not ready to submit, and the reason is arithmetic rather than doubt about the
changes: **after the whole series the input still does not translate.** The widest
statement list still ends in 8,230 contexts, because 8,191 of the 8,192 paths at
that branch point have finished and this series does not make that combination
joinable. The series moves the *rate* and the *peak before synthesis*, not the
outcome.

What would count as proving value, strongest first:

1. **The input translates.** The one lever the measurements support is handing each
   switch arm its own continuation (`Cps.stl_cm_fun`) so that a branch point with
   one continuing and one exiting path keeps the staying path joined instead of
   duplicating the rest of the block thirteen deep. Expected effect on this input:
   8,230 → ~14 contexts. Seven files. This is what makes the rest of the series
   matter, and it is not attempted here.
2. **A crate that used to die now completes**, reproducibly, with byte-identical
   output against a run at a larger ceiling. Nothing in the series is measured that
   way today.
3. Failing both, the per-unit wins stand on their own for a maintainer with their
   own oversized input: statement evaluations 6.5× down, one fork 594 words instead
   of a whole-environment copy, per-path retention 17,108 → 14,769 words, a trace
   that cannot grow with the iteration count.

Every number here was measured on one machine, one worker, on LLBC inputs
generated by Charon at the pinned commit. They are not a benchmark suite. No test
in the series asserts a memory figure: the tests pin *contracts* (a fork does not
scale with the environment; a trace does not grow with pushes) rather than
thresholds, because a threshold on one host would be flaky.

## 6. Branch list

Every branch is on the fork, off `main`. Each is a prefix of the series: branch
*n* contains branches 0…*n*−1, so the series applies, reviews and builds in order.
Where a unit is independent of what precedes it, the dependency is stated in the
unit's section above.

Tips are the shas as first pushed; rebasing any unit changes every tip after it, so
treat them as a starting point for `git log`, not as a pin.

| # | branch | tip | base | commits | files (unit alone) | subject |
|---|---|---|---|---|---|---|
| 00 | `upstream/00-generic-crate-names` | `205483411` | `main` | 1 | 6 (+21/−22) | describe measured inputs generically |
| 01 | `upstream/01-test-runner-skip-regex` | `6dd6f7cc7` | 00 | 1 | 1 (+1/−1) | parse a backend name containing a digit |
| 02 | `upstream/02-skip-noop-statements` | `e0c33fd19` | 01 | 1 | 2 (+73/−18) | skip statements that cannot change the context |
| 03 | `upstream/03-bounded-trace-ring` | `92abc5d79` | 02 | 1 | 4 (+170/−3) | bound the retained fixed-point trace |
| 04 | `upstream/04-share-context-rewrites` | `c69820e5c` | 03 | 1 | 7 (+557/−97) | share the unchanged parts of an environment |
| 05 | `upstream/05-share-across-forks` | `f5cf797b2` | 04 | 1 | 3 (+168/−3) | share the environment across forks |
| 06 | `upstream/06-join-decision` | `98e326290` | 05 | 1 | 5 (+208/−56) | decide a switch join from its results |
| 07 | `upstream/07-fn-item-regions` | `aafdc05cd` | 06 | 1 | 8 (+321/−64) | a function item's own regions |
| 08 | `upstream/08-lean-iterator-models` | `c1e24fcc7` | 07 | 2 | 12 (+2009/−256) | model `Iterator`'s provided methods (Lean) |

Why the bases are chained rather than each cut from `main`: units 02–06 change the
same three files (`InterpStatements.ml`, `Cps.ml`, `Contexts.ml`) within a few
hundred lines of each other, so parallel branches would each need a hand-resolved
merge to be reviewable together. A prefix chain costs a reviewer nothing — the
diff of branch *n* against *n*−1 is exactly the unit — and it guarantees the
series applies in order. 01, 07 and 08 are the parts that are genuinely
independent of the interpreter work; they are still chained for that same reason,
and their sections say what they actually need.

Ordering note for submission: the fork's `main` is upstream `main` plus 36
fork-only commits (parallel translation, an older `Diagnose` module, wide-enum
support, trait-dictionary parameters, nested-loop-exit desugaring). Units 01, 02,
03, 05, 06 and 08 touch only files upstream has — new files aside — and should
rebase onto upstream `main` with little work. 04 also touches
`Contexts.ml`/`InterpExpansion.ml`, which the fork has moved, and 07 has the one
fork-only test file noted in its section. Whatever order they are sent in, each one
should be rebased individually and re-run against the corpus — the point of the
corpus step is that it is cheap and it catches what `@runtest` cannot.
