(* Regression tests for the per-backend names in [ExtractBase].

   Extraction names types for the target backend, and two of those names are not what a naive
   [Printf] would produce: Lean calls binary32 [Float32] and binary64 [Float], while F*, Coq and
   HOL4 spell every float width in lower case. A refactor that matched on the pair
   [(backend (), float_ty)] once sent F128 to the non-Lean backends as [F128], because its
   catch-all arm sat after the backend-specific ones -- a name no backend defines, emitted
   silently. These cases pin the whole table so an arm cannot quietly move.

   Run with `dune build @runtest` from src/. *)

open Aeneas
open Types
open Values

let failures = ref 0

let expect (what : string) (expected : string) (actual : string) =
  if expected <> actual then begin
    incr failures;
    Printf.printf "FAIL  %-46s expected %-9s got %-9s\n" what expected actual
  end
  else Printf.printf "PASS  %-46s %s\n" what actual

let check (backend_name : string) (cases : (float_type * string) list) =
  Config.set_backend backend_name;
  List.iter
    (fun (ty, expected) ->
      let width =
        match ty with
        | F16 -> "16"
        | F32 -> "32"
        | F64 -> "64"
        | F128 -> "128"
      in
      expect
        (Printf.sprintf "%s, F%s" (Config.backend_to_string (Config.backend ())) width)
        expected
        (ExtractBase.float_name ty))
    cases

let () =
  check "lean"
    [
      (F16, "F16");
      (F32, "Float32");
      (F64, "Float");
      (F128, "F128");
    ];
  (* The three that share a convention must not diverge from each other. *)
  List.iter
    (fun b ->
      check b
        [
          (F16, "f16");
          (F32, "f32");
          (F64, "f64");
          (F128, "f128");
        ])
    [ "fstar"; "coq"; "hol4" ];
  (* [rocq] is accepted as a spelling of coq and must not fall through to another backend. *)
  check "rocq" [ (F64, "f64"); (F128, "f128") ];

  if !failures = 0 then Printf.printf "\nbackend names: all contracts hold\n"
  else begin
    Printf.printf "\nbackend names: %d contract(s) broken\n" !failures;
    exit 1
  end
