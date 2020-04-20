open Base
open Candidate

type 'a t_open = {
  delay: bool;
  default_state: 'a;
  compute: 'a -> string -> ('a * Candidate.t list);
}

type t = S : 'a t_open  -> t

(* Useful functions *)
let (/) = Caml.Filename.concat

let getenv var =
  try Caml.Sys.getenv var
  with Caml.Not_found -> ""

(* Word manipulation *)
let rec compute_word_index ?(acc = 0) words position = match words with
  | [] -> acc, 0, "", ""
  | t :: q ->
    if position <= String.length t then (
      acc, position, String.sub t ~pos:0 ~len:position,
      String.sub t ~pos:position ~len:(String.length t - position)
    ) else
      compute_word_index ~acc:(acc + 1) q (position - String.length t - 1)

type word_result = {
  word: string;
  before: string list;
  after: string list;
  index: int;
  index_inside: int;
  before_inside: string;
  after_inside: string;
  new_word : string * string -> string * string;
}

let get_word ?(once = false) sep before after =
  let total = before ^ after in
  if String.is_empty total then {
    word = ""; before = []; after = []; index = 0; index_inside = 0;
    before_inside = ""; after_inside = ""; new_word = (fun (a, b) -> a, b)
  } else
    let words =
      if not once then String.split ~on:sep total else
      let (a, b) = try String.lsplit2_exn ~on:sep total with _ -> total, "" in
      [a; b]
    in
    let word_index, index_inside, before_inside, after_inside =
      compute_word_index words (String.length before)
    in
    let word = List.nth_exn words word_index in
    let before, after = List.split_n words word_index in
    let after = List.tl_exn after in
    {
      word; index = word_index; index_inside; before; after;
      before_inside;
      after_inside;
      new_word = begin fun (bef, aft) ->
        let sep = Char.to_string sep in
        String.concat ~sep (before @ [bef]), String.concat ~sep (aft :: after)
      end
    }


let complete_in_word ?(drop_cont = false) separator f before after =
  let w = get_word separator before after in
  let before, after = w.new_word (f w.before_inside w.after_inside) in
  before, if drop_cont then "" else after

(* ? *)
let _ = complete_in_word

let match_in_word separator f query =
  let { word ; _ } = get_word separator query "" in
  f word

let dirname s =
  if String.is_empty s then ""
  else if Char.equal s.[String.length s -1] '/' then s
  else match Caml.Filename.dirname s with
  | "." -> ""
  | s -> s

let basename s =
  if String.is_empty s then ""
  else if Char.equal s.[String.length s -1] '/' then ""
  else Caml.Filename.basename s

let expand_tilde s = try
  Str.global_replace (Str.regexp "^~") (getenv "HOME") s
  with _ -> s

(* Actual sources *)
let files ?(filter=fun _ -> true) root =
  let root = root / "" in (* make it end by a slash *)
  let compute (old_dir, cache) query =
    let query = expand_tilde query in
    let directory = if not (String.is_empty query) && Char.equal query.[0] '/' then
        dirname query
      else
        root / dirname query
    in
    if String.equal old_dir directory && not (List.is_empty cache) then
      ((directory, cache), cache)
    else
      let files = try Caml.Sys.readdir directory with _ -> [||] in
      let candidates =
        Array.to_list files |>
        List.filter_map ~f:(fun file ->
          let abs_path = directory / file in
          if not (filter abs_path) then None else
          let real, display =
            if Caml.Sys.file_exists abs_path && Caml.Sys.is_directory abs_path then
              abs_path ^ "/", file ^ "/"
            else
              abs_path, file
          in
          let matching_function =
            match_in_word '/' (fun query ->
              Matching.match_query ~candidate:display (basename query)
            )
          in
          Some Candidate.(
            make ~completion:real ~real ~doc:abs_path
              ~matching_function display
          )
        )
      in
      ((directory, candidates), candidates)
  in
  S { delay = false ; default_state = (root, []) ; compute }

let from_list_aux (display, real, doc) =
  Candidate.make ~real ~doc display

let from_list_rev list =
  let candidates = List.rev_map ~f:from_list_aux list in
  S { delay = false; default_state = ();
      compute = (fun () _ -> ((), candidates)) }

let from_list_lazy list =
  let candidates = lazy (List.map ~f:from_list_aux (Lazy.force list)) in
  S { delay = false; default_state = ();
      compute = (fun () _ -> ((), Lazy.force candidates)) }

let from_list_lazy_ list =
  from_list_lazy (lazy (List.map ~f:(fun s -> s, s, "") (Lazy.force list)))

let from_list list = from_list_lazy (lazy list)
let from_list_ list = from_list_lazy_ (lazy list)
let from_list_rev_ list = List.rev_map ~f:(fun x -> x, x, "") list |> from_list


let stdin ?sep () =
  let open Stdio in
  List.map (In_channel.input_lines stdin) ~f:(fun s ->
    match sep with
    | None -> s, s, ""
    | Some c ->
      try
        let display, real = String.lsplit2_exn s ~on:c in
        display, real, ""
      with _ -> s, s, ""
  ) |> from_list

let binaries =
  let aux s =
    let helper s' =
      let full_path = s / s' in
      try
        let { Unix. st_perm ; _ } = Unix.stat full_path in
        if st_perm land 1 = 1 then Some (s', full_path) else None
      with Unix.Unix_error (Unix.ENOENT, "stat", _) ->
        (* File doesn't exist... Broken link? *)
        None
    in
    try Array.to_list (Caml.Sys.readdir s) |> List.filter_map ~f:helper
    with _ -> []
  in
  let lower_compare s1 s2 = String.(compare (lowercase s1) (lowercase s2)) in
  lazy (
    String.split ~on:':' (getenv "PATH")
    |> List.concat_map ~f:aux
    |> List.sort ~compare:(fun (s1, _) (s2, _) -> lower_compare s1 s2)
    |> List.map ~f:(fun (x, y) -> (x, y, ""))
    |> from_list
  )

let empty = S {
  delay = false;
  default_state = ();
  compute = fun _ _ -> ((), [])
}


type state = ST : 'a * 'a t_open -> state
let switch list =
  S {
    delay = false;
    default_state = None;
    compute = fun st query ->
      let (S source) =
        Lazy.force (snd (List.find_exn ~f:(fun (f, _b) -> f query) list))
      in
      match st with
      | Some (ST (state, source'))
        when phys_equal (Caml.Obj.magic source') (Caml.Obj.magic source) ->
        let (state, answer) = source'.compute state query in
        Some (ST (state, source')), answer
      | _ ->
        let (state, answer) = source.compute source.default_state query in
        Some (ST (state, source)), answer
  }

let paths ~coupled_with =
  switch [
    String.is_prefix ~prefix:"./", lazy (files (Caml.Sys.getcwd ()));
    String.is_prefix ~prefix: "~/", lazy (files (getenv "HOME"));
    String.is_prefix ~prefix:"/",  lazy (files "/");
    (fun _ -> true), Lazy.from_val coupled_with
  ]

let initialize (S x) = ST (x.default_state, x)

let update_candidates f (S x) =
    S { x with
      compute = (fun state query ->
        let state', candidates = x.compute state query in
        state', List.map ~f candidates)
    }

let update_matching f =
  update_candidates (fun c ->
    { c with matching_function = f c.matching_function })

let update_real f =
  update_candidates (fun c ->
    { c with real = f c.real })

let update_display f =
  update_candidates (fun c ->
    { c with display = f c.display })

let update_completion f =
  update_candidates (fun c ->
    { c with completion = f c.completion })

