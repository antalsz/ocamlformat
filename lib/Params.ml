(**************************************************************************)
(*                                                                        *)
(*                              OCamlFormat                               *)
(*                                                                        *)
(*            Copyright (c) Facebook, Inc. and its affiliates.            *)
(*                                                                        *)
(*      This source code is licensed under the MIT license found in       *)
(*      the LICENSE file in the root directory of this source tree.       *)
(*                                                                        *)
(**************************************************************************)

module Location = Migrate_ast.Location
open Extended_ast
open Asttypes
open Fmt

let parens_if parens (c : Conf.t) ?(disambiguate = false) k =
  if disambiguate && c.fmt_opts.disambiguate_non_breaking_match.v then
    wrap_if_fits_or parens "(" ")" k
  else if not parens then k
  else
    match c.fmt_opts.indicate_multiline_delimiters.v with
    | `Space ->
        Fmt.fits_breaks "(" "(" $ k $ Fmt.fits_breaks ")" ~hint:(1, 0) ")"
    | `Closing_on_separate_line ->
        Fmt.fits_breaks "(" "(" $ k $ Fmt.fits_breaks ")" ~hint:(1000, 0) ")"
    | `No -> wrap "(" ")" k

let parens c ?disambiguate k = parens_if true c ?disambiguate k

module Exp = struct
  module Infix_op_arg = struct
    let wrap (c : Conf.t) ?(parens_nested = false) ~parens k =
      if parens || parens_nested then
        let opn, hint, cls =
          if parens || Poly.(c.fmt_opts.infix_precedence.v = `Parens) then
            match c.fmt_opts.indicate_multiline_delimiters.v with
            | `Space -> ("( ", Some (1, 0), ")")
            | `No -> ("(", Some (0, 0), ")")
            | `Closing_on_separate_line -> ("(", Some (1000, 0), ")")
          else ("", None, "")
        in
        wrap_if_k (parens || parens_nested) (Fmt.fits_breaks "(" opn)
          (Fmt.fits_breaks ")" ?hint cls)
          k
      else k
  end

  let wrap (c : Conf.t) ?(disambiguate = false) ?(fits_breaks = true)
      ?(offset_closing_paren = 0) ~parens k =
    if disambiguate && c.fmt_opts.disambiguate_non_breaking_match.v then
      wrap_if_fits_or parens "(" ")" k
    else if not parens then k
    else if fits_breaks then wrap_fits_breaks ~space:false c "(" ")" k
    else
      match c.fmt_opts.indicate_multiline_delimiters.v with
      | `Space ->
          Fmt.fits_breaks "(" "(" $ k $ Fmt.fits_breaks ")" ~hint:(1, 0) ")"
      | `Closing_on_separate_line ->
          Fmt.fits_breaks "(" "(" $ k
          $ Fmt.fits_breaks ")" ~hint:(1000, offset_closing_paren) ")"
      | `No -> wrap "(" ")" k
end

let get_or_pattern_sep ?(cmts_before = false) ?(space = false) (c : Conf.t)
    ~ctx =
  let nspaces = if cmts_before then 1000 else 1 in
  match ctx with
  | Ast.Exp {pexp_desc= Pexp_function _ | Pexp_match _ | Pexp_try _; _} -> (
    match c.fmt_opts.break_cases.v with
    | `Nested -> break nspaces 0 $ str "| "
    | _ -> (
        let nspaces =
          match c.fmt_opts.break_cases.v with
          | `All | `Vertical -> 1000
          | _ -> nspaces
        in
        match c.fmt_opts.indicate_nested_or_patterns.v with
        | `Space ->
            cbreak ~fits:("", nspaces, "| ")
              ~breaks:("", 0, if space then " | " else " |")
        | `Unsafe_no -> break nspaces 0 $ str "| " ) )
  | _ -> break nspaces 0 $ str "| "

type cases =
  { leading_space: Fmt.t
  ; bar: Fmt.t
  ; box_all: Fmt.t -> Fmt.t
  ; box_pattern_arrow: Fmt.t -> Fmt.t
  ; break_before_arrow: Fmt.t
  ; break_after_arrow: Fmt.t
  ; open_paren_branch: Fmt.t
  ; break_after_opening_paren: Fmt.t
  ; close_paren_branch: Fmt.t }

let get_cases (c : Conf.t) ~first ~indent ~parens_branch ~xbch =
  let beginend =
    match xbch.Ast.ast with
    | {pexp_desc= Pexp_beginend _; _} -> true
    | _ -> false
  in
  let open_paren_branch =
    if beginend then fmt "@;<1 0>begin" else fmt_if parens_branch " ("
  in
  let close_paren_branch =
    if beginend then
      let offset =
        match c.fmt_opts.break_cases.v with `Nested -> 0 | _ -> -2
      in
      fits_breaks " end" ~level:1 ~hint:(1000, offset) "end"
    else
      fmt_if_k parens_branch
        ( match c.fmt_opts.indicate_multiline_delimiters.v with
        | `Space -> fmt "@ )"
        | `No -> fmt "@,)"
        | `Closing_on_separate_line -> fmt "@;<1000 -2>)" )
  in
  match c.fmt_opts.break_cases.v with
  | `Fit ->
      { leading_space= fmt_if (not first) "@ "
      ; bar= fmt_or_k first (if_newline "| ") (str "| ")
      ; box_all= hvbox indent
      ; box_pattern_arrow= hovbox 2
      ; break_before_arrow= fmt "@;<1 0>"
      ; break_after_arrow= noop
      ; open_paren_branch
      ; break_after_opening_paren= fmt "@ "
      ; close_paren_branch }
  | `Nested ->
      { leading_space= fmt_if (not first) "@ "
      ; bar= fmt_or_k first (if_newline "| ") (str "| ")
      ; box_all= Fn.id
      ; box_pattern_arrow= hovbox 0
      ; break_before_arrow= fmt "@;<1 2>"
      ; break_after_arrow= fmt_if (not parens_branch) "@;<0 3>"
      ; open_paren_branch
      ; break_after_opening_paren= fmt_or (indent > 2) "@;<1 4>" "@;<1 2>"
      ; close_paren_branch }
  | `Fit_or_vertical ->
      { leading_space= break_unless_newline 1000 0
      ; bar= str "| "
      ; box_all= hovbox indent
      ; box_pattern_arrow= hovbox 0
      ; break_before_arrow= fmt "@;<1 2>"
      ; break_after_arrow= fmt_if (not parens_branch) "@;<0 3>"
      ; open_paren_branch
      ; break_after_opening_paren= fmt "@ "
      ; close_paren_branch }
  | `Toplevel | `All ->
      { leading_space= break_unless_newline 1000 0
      ; bar= str "| "
      ; box_all= hvbox indent
      ; box_pattern_arrow= hovbox 0
      ; break_before_arrow= fmt "@;<1 2>"
      ; break_after_arrow= fmt_if (not parens_branch) "@;<0 3>"
      ; open_paren_branch
      ; break_after_opening_paren= fmt "@ "
      ; close_paren_branch }
  | `Vertical ->
      { leading_space= break_unless_newline 1000 0
      ; bar= str "| "
      ; box_all= hvbox indent
      ; box_pattern_arrow= hovbox 0
      ; break_before_arrow= fmt "@;<1 2>"
      ; break_after_arrow= fmt_if (not parens_branch) "@;<0 3>"
      ; open_paren_branch
      ; break_after_opening_paren= break 1000 0
      ; close_paren_branch }

let wrap_collec c ~space_around opn cls =
  if space_around then wrap_k (str opn $ char ' ') (break 1 0 $ str cls)
  else wrap_fits_breaks c opn cls

let wrap_record (c : Conf.t) =
  wrap_collec c ~space_around:c.fmt_opts.space_around_records.v "{" "}"

let wrap_tuple (c : Conf.t) ~parens ~no_parens_if_break =
  if parens then wrap_fits_breaks c "(" ")"
  else if no_parens_if_break then Fn.id
  else wrap_k (fits_breaks "" "( ") (fits_breaks "" ~hint:(1, 0) ")")

type record_type =
  { docked_before: Fmt.t
  ; break_before: Fmt.t
  ; box_record: Fmt.t -> Fmt.t
  ; box_spaced: bool
  ; sep_before: Fmt.t
  ; sep_after: Fmt.t
  ; break_after: Fmt.t
  ; docked_after: Fmt.t }

let get_record_type (c : Conf.t) =
  let sparse_type_decl = Poly.(c.fmt_opts.type_decl.v = `Sparse) in
  let space = if c.fmt_opts.space_around_records.v then 1 else 0 in
  let dock = c.fmt_opts.dock_collection_brackets.v in
  let break_before, sep_before, sep_after =
    match c.fmt_opts.break_separators.v with
    | `Before ->
        ( fmt_or_k dock (break space 2) (fmt "@ ")
        , fmt_or sparse_type_decl "@;<1000 0>; " "@,; "
        , noop )
    | `After ->
        ( fmt_or_k dock (break space 0) (fmt "@ ")
        , noop
        , fmt_or_k dock
            (fmt_or sparse_type_decl "@;<1000 0>" "@ ")
            (fmt_or sparse_type_decl "@;<1000 2>" "@;<1 2>") )
  in
  { docked_before= fmt_if dock " {"
  ; break_before
  ; box_record= (fun k -> if dock then k else hvbox 0 (wrap_record c k))
  ; box_spaced= c.fmt_opts.space_around_records.v
  ; sep_before
  ; sep_after
  ; break_after= fmt_if_k dock (break space (-2))
  ; docked_after= fmt_if dock "}" }

type elements_collection =
  { box: Fmt.t -> Fmt.t
  ; sep_before: Fmt.t
  ; sep_after_non_final: Fmt.t
  ; sep_after_final: Fmt.t }

type elements_collection_record_expr = {break_after_with: Fmt.t}

type elements_collection_record_pat = {wildcard: Fmt.t}

let get_record_expr (c : Conf.t) =
  let space = if c.fmt_opts.space_around_records.v then 1 else 0 in
  let dock = c.fmt_opts.dock_collection_brackets.v in
  let box k =
    if dock then hvbox 0 (wrap "{" "}" (break space 2 $ k $ break space 0))
    else hvbox 0 (wrap_record c k)
  in
  ( ( match c.fmt_opts.break_separators.v with
    | `Before ->
        { box
        ; sep_before= fmt "@,; "
        ; sep_after_non_final= noop
        ; sep_after_final= noop }
    | `After ->
        { box
        ; sep_before= noop
        ; sep_after_non_final= fmt ";@;<1 2>"
        ; sep_after_final= fmt_if_k dock (fits_breaks ~level:0 "" ";") } )
  , {break_after_with= break 1 2} )

let box_collec (c : Conf.t) =
  match c.fmt_opts.break_collection_expressions.v with
  | `Wrap -> hovbox
  | `Fit_or_vertical -> hvbox

let collection_expr (c : Conf.t) ~space_around opn cls =
  let space = if space_around then 1 else 0 in
  let dock = c.fmt_opts.dock_collection_brackets.v in
  let offset = if dock then -2 else String.length opn - 1 in
  match c.fmt_opts.break_separators.v with
  | `Before ->
      { box=
          (fun k ->
            if dock then
              hvbox 0
                (wrap_k (str opn) (str cls)
                   ( break space (String.length opn + 1)
                   $ box_collec c 0 k $ break space 0 ) )
            else box_collec c 0 (wrap_collec c ~space_around opn cls k) )
      ; sep_before= break 0 offset $ str "; "
      ; sep_after_non_final= noop
      ; sep_after_final= noop }
  | `After ->
      { box=
          (fun k ->
            if dock then
              hvbox 0
                (wrap_k (str opn) (str cls)
                   (break space 2 $ box_collec c 0 k $ break space 0) )
            else box_collec c 0 (wrap_collec c ~space_around opn cls k) )
      ; sep_before= noop
      ; sep_after_non_final=
          fmt_or_k dock (fmt ";@;<1 0>")
            (char ';' $ break 1 (String.length opn + 1))
      ; sep_after_final= fmt_if_k dock (fits_breaks ~level:1 "" ";") }

let get_list_expr (c : Conf.t) =
  collection_expr c ~space_around:c.fmt_opts.space_around_lists.v "[" "]"

let get_array_expr (c : Conf.t) =
  collection_expr c ~space_around:c.fmt_opts.space_around_arrays.v "[|" "|]"

let get_iarray_expr (c : Conf.t) =
  collection_expr c ~space_around:c.fmt_opts.space_around_arrays.v "[:" ":]"

(* Modeled after [collection_expr] in [`After] mode *)
let wrap_comprehension (c : Conf.t) ~space_around ~punctuation comp =
  let opn = "[" ^ punctuation in
  let cls = punctuation ^ "]" in
  let space = if space_around then 1 else 0 in
  if c.fmt_opts.dock_collection_brackets.v then
    hvbox 0
      (wrap_k (str opn) (str cls)
         (break space 2 $ hvbox 0 comp $ break space 0) )
  else hvbox 0 (wrap_collec c ~space_around opn cls comp)

let box_pattern_docked (c : Conf.t) ~ctx ~space_around opn cls k =
  let space = if space_around then 1 else 0 in
  let indent_opn, indent_cls =
    match (ctx, c.fmt_opts.break_separators.v) with
    | Ast.Exp {pexp_desc= Pexp_match _ | Pexp_try _; _}, `Before ->
        (String.length opn - 3, 1 - String.length opn)
    | Ast.Exp {pexp_desc= Pexp_match _ | Pexp_try _; _}, `After -> (-3, 1)
    | Ast.Exp {pexp_desc= Pexp_let _; _}, _ -> (-4, 0)
    | _ -> (0, 0)
  in
  hvbox indent_opn
    (wrap_k (str opn) (str cls) (break space 2 $ k $ break space indent_cls))

let get_record_pat (c : Conf.t) ~ctx =
  let params, _ = get_record_expr c in
  let box =
    if c.fmt_opts.dock_collection_brackets.v then
      box_pattern_docked c ~ctx
        ~space_around:c.fmt_opts.space_around_records.v "{" "}"
    else params.box
  in
  ( {params with box}
  , {wildcard= params.sep_before $ str "_" $ params.sep_after_final} )

let collection_pat (c : Conf.t) ~ctx ~space_around opn cls =
  let params = collection_expr c ~space_around opn cls in
  let box =
    if c.fmt_opts.dock_collection_brackets.v then
      box_collec c 0 >> box_pattern_docked c ~ctx ~space_around opn cls
    else params.box
  in
  {params with box}

let get_list_pat (c : Conf.t) ~ctx =
  collection_pat c ~ctx ~space_around:c.fmt_opts.space_around_lists.v "[" "]"

let get_array_pat (c : Conf.t) ~ctx =
  collection_pat c ~ctx ~space_around:c.fmt_opts.space_around_arrays.v "[|"
    "|]"

let get_iarray_pat (c : Conf.t) ~ctx =
  collection_pat c ~ctx ~space_around:c.fmt_opts.space_around_arrays.v "[:"
    ":]"

type if_then_else =
  { box_branch: Fmt.t -> Fmt.t
  ; cond: Fmt.t
  ; box_keyword_and_expr: Fmt.t -> Fmt.t
  ; branch_pro: Fmt.t
  ; wrap_parens: Fmt.t -> Fmt.t
  ; box_expr: bool option
  ; expr_pro: Fmt.t option
  ; expr_eol: Fmt.t option
  ; break_end_branch: Fmt.t
  ; space_between_branches: Fmt.t }

let get_if_then_else (c : Conf.t) ~first ~last ~parens_bch ~parens_prev_bch
    ~xcond ~xbch ~expr_loc ~fmt_extension_suffix ~fmt_attributes ~fmt_cond =
  let imd = c.fmt_opts.indicate_multiline_delimiters.v in
  let beginend =
    match xbch.Ast.ast with
    | {pexp_desc= Pexp_beginend _; _} -> true
    | _ -> false
  in
  let wrap_parens ~wrap_breaks k =
    if beginend then wrap "begin" "end" (wrap_breaks k)
    else if parens_bch then wrap "(" ")" (wrap_breaks k)
    else k
  in
  let get_parens_breaks ~opn_hint:(oh_space, oh_other)
      ~cls_hint:(ch_sp, ch_sl) =
    let brk hint = fits_breaks "" ~hint "" in
    if beginend then
      let _, offset = ch_sl in
      wrap_k (brk oh_other) (break 1000 offset)
    else
      match imd with
      | `Space -> wrap_k (brk oh_space) (brk ch_sp)
      | `No -> wrap_k (brk oh_other) noop
      | `Closing_on_separate_line -> wrap_k (brk oh_other) (brk ch_sl)
  in
  let cond () =
    match xcond with
    | Some xcnd ->
        hvbox 0
          ( hvbox 2
              ( fmt_if (not first) "else "
              $ str "if"
              $ fmt_if_k first (fmt_opt fmt_extension_suffix)
              $ fmt_attributes $ fmt "@ " $ fmt_cond xcnd )
          $ fmt "@ then" )
    | None -> str "else"
  in
  let branch_pro = fmt_or (beginend || parens_bch) " " "@;<1 2>" in
  match c.fmt_opts.if_then_else.v with
  | `Compact ->
      { box_branch= hovbox 2
      ; cond= cond ()
      ; box_keyword_and_expr= Fn.id
      ; branch_pro= fmt_or (beginend || parens_bch) " " "@ "
      ; wrap_parens=
          wrap_parens
            ~wrap_breaks:
              (get_parens_breaks
                 ~opn_hint:((1, 0), (0, 0))
                 ~cls_hint:((1, 0), (1000, -2)) )
      ; box_expr= Some false
      ; expr_pro= None
      ; expr_eol= None
      ; break_end_branch= noop
      ; space_between_branches= fmt "@ " }
  | `K_R ->
      { box_branch= Fn.id
      ; cond= cond ()
      ; box_keyword_and_expr= Fn.id
      ; branch_pro
      ; wrap_parens= wrap_parens ~wrap_breaks:(wrap_k (break 1000 2) noop)
      ; box_expr= Some false
      ; expr_pro= None
      ; expr_eol= Some (fmt "@;<1 2>")
      ; break_end_branch=
          fmt_if_k (parens_bch || beginend || not last) (break 1000 0)
      ; space_between_branches= fmt_if (beginend || parens_bch) " " }
  | `Fit_or_vertical ->
      { box_branch=
          hovbox
            ( match imd with
            | `Closing_on_separate_line when parens_prev_bch -> -2
            | _ -> 0 )
      ; cond= cond ()
      ; box_keyword_and_expr= Fn.id
      ; branch_pro
      ; wrap_parens=
          wrap_parens
            ~wrap_breaks:
              (get_parens_breaks
                 ~opn_hint:((1, 2), (0, 2))
                 ~cls_hint:((1, 0), (1000, 0)) )
      ; box_expr= Some false
      ; expr_pro=
          Some
            (fmt_if_k
               (not (Location.is_single_line expr_loc c.fmt_opts.margin.v))
               (break_unless_newline 1000 2) )
      ; expr_eol= Some (fmt "@;<1 2>")
      ; break_end_branch= noop
      ; space_between_branches=
          fmt
            ( match imd with
            | `Closing_on_separate_line when beginend || parens_bch -> " "
            | _ -> "@ " ) }
  | `Vertical ->
      { box_branch= Fn.id
      ; cond= cond ()
      ; box_keyword_and_expr= Fn.id
      ; branch_pro
      ; wrap_parens=
          wrap_parens
            ~wrap_breaks:
              (get_parens_breaks
                 ~opn_hint:((1, 2), (0, 2))
                 ~cls_hint:((1, 0), (1000, 0)) )
      ; box_expr= None
      ; expr_pro= Some (break_unless_newline 1000 2)
      ; expr_eol= None
      ; break_end_branch= noop
      ; space_between_branches=
          fmt
            ( match imd with
            | `Closing_on_separate_line when parens_bch -> " "
            | _ -> "@ " ) }
  | `Keyword_first ->
      { box_branch= Fn.id
      ; cond=
          opt xcond (fun xcnd ->
              hvbox 2
                ( fmt_or_k first
                    (str "if" $ fmt_opt fmt_extension_suffix)
                    (str "else if")
                $ fmt_attributes
                $ fmt_or (Option.is_some fmt_extension_suffix) "@ " " "
                $ fmt_cond xcnd )
              $ fmt "@ " )
      ; box_keyword_and_expr=
          (fun k -> hvbox 2 (fmt_or (Option.is_some xcond) "then" "else" $ k))
      ; branch_pro= fmt_or (beginend || parens_bch) " " "@ "
      ; wrap_parens=
          wrap_parens
            ~wrap_breaks:
              (get_parens_breaks
                 ~opn_hint:((1, 0), (0, 0))
                 ~cls_hint:((1, 0), (1000, -2)) )
      ; box_expr= Some false
      ; expr_pro= None
      ; expr_eol= None
      ; break_end_branch= noop
      ; space_between_branches= fmt "@ " }

let match_indent ?(default = 0) (c : Conf.t) ~(ctx : Ast.t) =
  match (c.fmt_opts.match_indent_nested.v, ctx) with
  | `Always, _ | _, (Top | Sig _ | Str _) -> c.fmt_opts.match_indent.v
  | _ -> default

let function_indent ?(default = 0) (c : Conf.t) ~(ctx : Ast.t) =
  match (c.fmt_opts.function_indent_nested.v, ctx) with
  | `Always, _ | _, (Top | Sig _ | Str _) -> c.fmt_opts.function_indent.v
  | _ -> default

let comma_sep (c : Conf.t) : Fmt.s =
  match c.fmt_opts.break_separators.v with
  | `Before -> "@,, "
  | `After -> ",@;<1 2>"

let semi_sep (c : Conf.t) : Fmt.s =
  match c.fmt_opts.break_separators.v with
  | `Before -> "@,; "
  | `After -> ";@;<1 2>"

module Align = struct
  (** Whether [exp] occurs in [args] as a labelled argument. *)
  let is_labelled_arg args exp =
    List.exists
      ~f:(function
        | Nolabel, _ -> false
        | Labelled _, x | Optional _, x -> phys_equal x exp )
      args

  let general (c : Conf.t) t =
    hvbox_if (not c.fmt_opts.align_symbol_open_paren.v) 0 t

  let infix_op = general

  let match_ = general

  let function_ (c : Conf.t) ~parens ~(ctx0 : Ast.t) ~self t =
    let align =
      match ctx0 with
      | Exp {pexp_desc= Pexp_infix (_, _, {pexp_desc= Pexp_function _; _}); _}
        ->
          false
      | Exp {pexp_desc= Pexp_apply (_, args); _}
        when is_labelled_arg args self ->
          false
      | _ -> parens && not c.fmt_opts.align_symbol_open_paren.v
    in
    hvbox_if align 0 t
end
