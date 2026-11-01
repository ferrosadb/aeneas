(* Regression tests for [ty_regions].

   [ty_regions] answers one question: which FREE regions does this type mention. A prepass
   rewrites body and variable regions to [RErased] (PrePasses.ml), so after prepasses a type may
   legitimately mention a region that is not free. Aborting on those answers a question the
   caller never asked, and takes the whole run with it.

   The three outcomes are pinned here together, because the fix must widen the accepted input
   without widening the accepted inconsistency: [RVar (Bound _)] reaching a free-region collector
   is a real bug and must keep raising.

   Run with `dune build @runtest` from src/. *)

open Aeneas
open Types

let scalar = TScalar (TInteger (Signed Isize))
let ref_to (r : region) : ty = TRef (r, scalar, RShared)
let free i : region = RVar (Free (RegionId.of_int i))
let bound i : region = RVar (Bound (0, RegionId.of_int i))
let failures = ref 0

let report name = function
  | Ok note -> Printf.printf "PASS  %-52s %s\n" name note
  | Error note ->
      incr failures;
      Printf.printf "FAIL  %-52s %s\n" name note

let describe (s : RegionId.Set.t) =
  Printf.sprintf "{%s}"
    (String.concat ", "
       (List.map string_of_int
          (List.map RegionId.to_int (RegionId.Set.elements s))))

let expect_returned name (f : unit -> RegionId.Set.t) (expected : int list) =
  match f () with
  | s ->
      let got =
        List.sort compare (List.map RegionId.to_int (RegionId.Set.elements s))
      in
      let expected = List.sort compare expected in
      if got = expected then
        report name (Ok (Printf.sprintf "returned %s" (describe s)))
      else
        report name
          (Error
             (Printf.sprintf "returned %s, expected {%s}" (describe s)
                (String.concat ", " (List.map string_of_int expected))))
  | exception Failure m ->
      report name
        (Error (Printf.sprintf "raised Failure(%S); expected no exception" m))

let expect_raise name (f : unit -> RegionId.Set.t) =
  match f () with
  | s ->
      report name
        (Error (Printf.sprintf "returned %s; expected a Failure" (describe s)))
  | exception Failure _ -> report name (Ok "raised Failure, as required")

let () =
  (* An erased region is not a free region: it must be skipped, not abort the caller. *)
  expect_returned "erased region is skipped"
    (fun () -> TypesUtils.ty_regions (ref_to RErased))
    [];
  (* Same for a body region: it belongs to a closure body, not to this signature. *)
  expect_returned "body region is skipped"
    (fun () -> TypesUtils.ty_regions (ref_to (RBody (RegionId.of_int 0))))
    [];
  (* Static is neither free nor a reason to raise. *)
  expect_returned "static region contributes nothing"
    (fun () -> TypesUtils.ty_regions (ref_to RStatic))
    [];
  (* The positive control: a free region is still collected, so an always-empty answer fails. *)
  expect_returned "free region is collected"
    (fun () -> TypesUtils.ty_regions (ref_to (free 7)))
    [ 7 ];
  (* A type that mentions all three still reports only the free one: the outer reference is
     erased and its pointee is a reference whose region is a body region, which in turn points at
     a free region nested one level deeper. *)
  expect_returned "free region under erased and body is reported"
    (fun () ->
      TypesUtils.ty_regions
        (TRef
           ( RErased,
             TRef (RBody (RegionId.of_int 1), ref_to (free 3), RShared),
             RShared )))
    [ 3 ];
  (* Erased nested inside another erased-only type is still no reason to raise. *)
  expect_returned "nested erased regions are skipped"
    (fun () -> TypesUtils.ty_regions (TRef (RErased, ref_to RErased, RMut)))
    [];
  (* The fix must not swallow the inconsistency it was never about. *)
  expect_raise "bound region still raises" (fun () ->
      TypesUtils.ty_regions (ref_to (bound 9)));

  if !failures = 0 then (
    Printf.printf "\nty_regions: all contracts hold\n";
    exit 0)
  else (
    Printf.printf "\nty_regions: %d contract(s) broken\n" !failures;
    exit 1)
