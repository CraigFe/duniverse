(* Note: changes to this file may require similar changes to lib/model.ml *)

let fop : Cudf_types.relop -> int -> int -> bool = function
  | `Eq -> (=)
  | `Neq -> (<>)
  | `Geq -> (>=)
  | `Gt -> (>)
  | `Leq -> (<=)
  | `Lt -> (<)

module Make (Context : S.CONTEXT) = struct
  type restriction = {
    kind : [ `Ensure | `Prevent ];
    expr : (Cudf_types.relop * Cudf_types.version) list; (* TODO: might not be a list *)
    (* NOTE: each list is a raw or the list is an OR case (see Cudf_types.vpkgforula) *)
  }

  type real_role = {
    context : Context.t;
    name : Cudf_types.pkgname;
  }

  type role =
    | Real of real_role               (* A role is usually an opam package name *)
    | Virtual of int * impl list      (* (int just for sorting) *)
  and real_impl = {
    pkg : Cudf.package;
    requires : dependency list;
  }
  and dependency = {
    drole : role;
    importance : [ `Essential | `Recommended | `Restricts ];
    restrictions : restriction list;
  }
  and impl =
    | RealImpl of real_impl                     (* An implementation is usually an opam package *)
    | VirtualImpl of int * dependency list      (* (int just for sorting) *)
    | Dummy                                     (* Used for diagnostics *)

  let rec pp_version f = function
    | RealImpl impl -> Fmt.int f impl.pkg.Cudf.version
    | VirtualImpl (_i, deps) -> Fmt.string f (String.concat "&" (List.map (fun d -> Fmt.to_to_string pp_role d.drole) deps))
    | Dummy -> Fmt.string f "(no version)"
  and pp_impl f = function
    | RealImpl impl -> Fmt.string f impl.pkg.Cudf.package
    | VirtualImpl _ as x -> pp_version f x
    | Dummy -> Fmt.string f "(no solution found)"
  and pp_role f = function
    | Real t -> Fmt.string f t.name
    | Virtual (_, impls) -> Fmt.pf f "%a" Fmt.(list ~sep:(unit "|") pp_impl) impls

  let pp_impl_long fmt = function
    | RealImpl impl -> Fmt.pf fmt "%s.%d" impl.pkg.Cudf.package impl.pkg.Cudf.version
    | VirtualImpl _ as x -> pp_version fmt x
    | Dummy -> Fmt.string fmt "(no solution found)"

  module Role = struct
    type t = role

    let pp = pp_role

    let compare a b =
      match a, b with
      | Real a, Real b -> String.compare a.name b.name
      | Virtual (a, _), Virtual (b, _) -> compare (a : int) b
      | Real _, Virtual _ -> -1
      | Virtual _, Real _ -> 1
  end

  let role context name = Real { context; name }

  let fresh_id =
    let i = ref 0 in
    fun () ->
      incr i;
      !i

  let virtual_impl ~context ~depends () =
    let depends = depends |> List.map (fun name ->
        let drole = role context name in
        { drole; importance = `Essential; restrictions = []}
      ) in
    VirtualImpl (fresh_id (), depends)

  let virtual_role impls =
    Virtual (fresh_id (), impls)

  type command = |          (* We don't use 0install commands anywhere *)
  type command_name = private string
  let pp_command _ = function (_:command) -> .
  let command_requires _role = function (_:command) -> .
  let get_command _impl _command_name = None

  type dep_info = {
    dep_role : Role.t;
    dep_importance : [ `Essential | `Recommended | `Restricts ];
    dep_required_commands : command_name list;
  }

  type requirements = {
    role : Role.t;
    command : command_name option;
  }

  let dummy_impl = Dummy

  let list_deps ~context ~importance ~kind deps =
    let rec aux = function
      | [[(name, constr)]] ->
        let drole = role context name in
        let restrictions =
          match constr with
          | None -> []
          | Some c -> [{kind; expr = [c]}]
        in
        [{ drole; restrictions; importance }]
      | [o] ->
        let impls = group_ors o in
        let drole = virtual_role impls in
        (* Essential because we must apply a restriction, even if its
           components are only restrictions. *)
        [{ drole; restrictions = []; importance = `Essential }]
      | x::y -> aux [x] @ aux y
      | [] -> []
    and group_ors = function
      | [expr] -> [VirtualImpl (fresh_id (), aux [[expr]])]
      | x::y -> group_ors [x] @ group_ors y
      | [] -> assert false (* TODO: implement false *)
    in
    aux deps

  let requires _ = function
    | Dummy -> [], []
    | VirtualImpl (_, deps) -> deps, []
    | RealImpl impl -> impl.requires, []

  let dep_info { drole; importance; restrictions = _ } =
    { dep_role = drole; dep_importance = importance; dep_required_commands = [] }

  type role_information = {
    replacement : Role.t option;
    impls : impl list;
  }

  type machine_group = private string   (* We don't use machine groups because opam is source-only. *)
  let machine_group _impl = None

  type conflict_class = private string
  let conflict_class _impl = []

  let ensure l = l

  let prevent l = List.map (fun x -> [x]) l

  let implementations = function
    | Virtual (_, impls) -> { impls; replacement = None }
    | Real role ->
      let context = role.context in
      let impls =
        Context.candidates context role.name
        |> List.filter_map (function
            | _, Some _rejection -> None
            | version, None ->
              let pkg = Context.load role.context (role.name, version) in
              let requires =
                let make_deps importance kind deps =
                  list_deps ~context ~importance ~kind deps
                in
                make_deps `Essential `Ensure (ensure pkg.Cudf.depends) @
                make_deps `Restricts `Prevent (prevent pkg.Cudf.conflicts)
              in
              Some (RealImpl {pkg; requires})
          )
      in
      { impls; replacement = None }

  let restrictions dependency = dependency.restrictions

  let meets_restriction impl { kind; expr } =
    match impl with
    | Dummy -> true
    | VirtualImpl _ -> assert false        (* Can't constrain version of a virtual impl! *)
    | RealImpl impl ->
      let aux (c, v) = fop c impl.pkg.Cudf.version v in
      let result = List.exists aux expr in
      match kind with
      | `Ensure -> result
      | `Prevent -> not result

  type rejection = Context.rejection

  let rejects role =
    match role with
    | Virtual _ -> [], []
    | Real role ->
      let context = role.context in
      let rejects =
        Context.candidates context role.name
        |> List.filter_map (function
            | _, None -> None
            | version, Some reason ->
              let pkg = Context.load role.context (role.name, version) in
              Some (RealImpl {pkg; requires = []}, reason)
          )
      in
      let notes = [] in
      rejects, notes

  let compare_version a b =
    match a, b with
    | RealImpl a, RealImpl b -> compare (a.pkg.Cudf.version : int) b.pkg.Cudf.version
    | VirtualImpl (ia, _), VirtualImpl (ib, _) -> compare (ia : int) ib
    | a, b -> compare a b

  let user_restrictions = function
    | Virtual _ -> None
    | Real role ->
      match Context.user_restrictions role.context role.name with
      | [] -> None
      | expr -> Some { kind = `Ensure; expr }

  let format_machine _impl = "(src)"

  let string_of_op = function
    | `Eq -> "="
    | `Geq -> ">="
    | `Gt -> ">"
    | `Leq -> "<="
    | `Lt -> "<"
    | `Neq -> "<>"

  let string_of_version_formula l =
    String.concat " & " (
      List.map (fun (rel, v) ->
          Printf.sprintf "%s %s" (string_of_op rel) (string_of_int v)
        ) l
    )

  let string_of_restriction = function
    | { kind = `Prevent; expr = [] } -> "conflict with all versions"
    | { kind = `Prevent; expr } -> Fmt.strf "not(%s)" (string_of_version_formula expr)
    | { kind = `Ensure; expr } -> string_of_version_formula expr

  let describe_problem _impl = Fmt.to_to_string Context.pp_rejection

  let version = function
    | RealImpl impl -> Some (impl.pkg.Cudf.package, impl.pkg.Cudf.version)
    | VirtualImpl _ -> None
    | Dummy -> None
end
