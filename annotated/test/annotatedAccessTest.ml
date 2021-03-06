(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2

open Ast
open Analysis
open Statement

open Test
open AnnotatedTest

module Access = Annotated.Access
module Class = Annotated.Class
module Attribute = Annotated.Attribute


type attribute = {
  name: string;
  defined: bool;
}


and stripped =
  | Attribute of attribute
  | Unknown
  | Signature
  | Value


and step = {
  annotation: Type.t;
  element: stripped;
}
[@@deriving compare, eq, show]


let test_fold _ =
  let resolution =
    populate_with_sources [
      parse
        ~qualifier:(Expression.Access.create "buitins")
        {|
          integer: int = 1
          string: str = 'string'

          class Class:
            attribute: int = 1
            def method(self) -> int: ...
          instance: Class

          def function() -> str: ...
        |};
      parse
        ~qualifier:(Expression.Access.create "os")
        {|
          os.sep: str = '/'
        |};
      parse
        ~qualifier:(Expression.Access.create "empty.stub")
        ~path:"empty/stub.pyi"
        "";
    ]
    |> resolution
  in
  let parse_annotation annotation =
    annotation
    |> parse_single_expression
    |> Resolution.parse_annotation resolution
  in
  let assert_fold access expected =
    let steps =
      let steps steps ~resolution:_ ~resolved ~element =
        let step =
          let open Access in
          let stripped element: stripped =
            match element with
            | Element.Attribute { Element.origin = Element.Module []; _ } ->
                Unknown
            | Element.Attribute { Element.attribute; defined; _ } ->
                Attribute { name = Expression.Access.show attribute; defined }
            | Element.Signature _ ->
                Signature
            | Element.Value ->
                Value
          in
          { annotation = Annotation.annotation resolved; element = stripped element }
        in
        step :: steps
      in
      parse_single_access access
      |> Access.create
      |> Access.fold ~resolution ~initial:[] ~f:steps
      |> List.rev
    in
    assert_equal
      ~printer:(fun steps -> List.map ~f:show_step steps |> String.concat ~sep:"\n")
      ~cmp:(List.equal ~equal:equal_step)
      expected
      steps
  in

  assert_fold "unknown" [{ annotation = Type.Top; element = Unknown }];
  assert_fold "unknown.unknown" [{ annotation = Type.Top; element = Unknown }];

  assert_fold "integer" [{ annotation = Type.integer; element = Value }];
  assert_fold "string" [{ annotation = Type.string; element = Value }];

  assert_fold "Class" [{ annotation = Type.meta (Type.primitive "Class"); element = Value }];
  assert_fold "instance" [{ annotation = Type.primitive "Class"; element = Value }];
  assert_fold
    "instance.attribute"
    [
      { annotation = Type.primitive "Class"; element = Value };
      { annotation = Type.integer; element = Attribute { name = "attribute"; defined = true } };
    ];
  assert_fold
    "instance.undefined.undefined"
    [
      { annotation = Type.primitive "Class"; element = Value };
      { annotation = Type.Top; element = Attribute { name = "undefined"; defined = false } };
    ];
  assert_fold
    "instance.method()"
    [
      { annotation = Type.primitive "Class"; element = Value };
      {
        annotation =
          parse_annotation "typing.Callable('Class.method')[[Named(self, $unknown)], int]";
        element = Attribute { name = "method"; defined = true };
      };
      { annotation = Type.integer; element = Signature };
    ];

  assert_fold
    "function()"
    [
      { annotation = parse_annotation "typing.Callable('function')[[], str]"; element = Value };
      { annotation = Type.string; element = Signature };
    ];

  assert_fold "os.sep" [{ annotation = Type.string; element = Value }];

  assert_fold "empty.stub.unknown" [{ annotation = Type.Top; element = Value }]


let assert_resolved sources access expected =
  let resolution =
    populate_with_sources sources
    |> resolution
  in
  let resolved =
    Access.fold
      ~resolution
      ~initial:Type.Top
      ~f:(fun _ ~resolution:_ ~resolved ~element:_ -> Annotation.annotation resolved)
      (Access.create (parse_single_access access))
  in
  assert_equal ~printer:Type.show ~cmp:Type.equal expected resolved


let test_module_exports _ =
  let assert_exports_resolved =
    assert_resolved
      [
        parse
          ~qualifier:(Expression.Access.create "implementing")
          {|
            def implementing.function() -> int: ...
            implementing.constant: int = 1
          |};
        parse
          ~qualifier:(Expression.Access.create "exporting")
          {|
            from implementing import function, constant
            from implementing import function as aliased
            from indirect import cyclic
          |};
        parse
          ~qualifier:(Expression.Access.create "indirect")
          {|
            from exporting import constant, cyclic
          |};
        parse
          ~qualifier:(Expression.Access.create "wildcard")
          {|
            from exporting import *
          |};
        parse
          ~qualifier:(Expression.Access.create "exporting_wildcard_default")
          {|
            from implementing import function, constant
            from implementing import function as aliased
            __all__ = ["constant"]
          |};
        parse
          ~qualifier:(Expression.Access.create "wildcard_default")
          {|
            from exporting_wildcard_default import *
          |};
      ]
  in

  assert_exports_resolved "implementing.constant" Type.integer;
  assert_exports_resolved "implementing.function()" Type.integer;
  assert_exports_resolved "implementing.undefined" Type.Top;

  assert_exports_resolved "exporting.constant" Type.integer;
  assert_exports_resolved "exporting.function()" Type.integer;
  assert_exports_resolved "exporting.aliased()" Type.integer;
  assert_exports_resolved "exporting.undefined" Type.Top;

  assert_exports_resolved "indirect.constant" Type.integer;
  assert_exports_resolved "indirect.cyclic" Type.Top;

  assert_exports_resolved "wildcard.constant" Type.integer;
  assert_exports_resolved "wildcard.cyclic" Type.Top;
  assert_exports_resolved "wildcard.aliased()" Type.integer;

  assert_exports_resolved "wildcard_default.constant" Type.integer;
  assert_exports_resolved "wildcard_default.aliased()" Type.Top;

  let assert_fixpoint_stop =
    assert_resolved
      [
        parse
          ~qualifier:(Expression.Access.create "loop.b")
          {|
            loop.b.b: int = 1
          |};
        parse
          ~qualifier:(Expression.Access.create "loop.a")
          {|
            from loop.b import b
          |};
        parse
          ~qualifier:(Expression.Access.create "loop")
          {|
            from loop.a import b
          |};
        parse
          ~qualifier:(Expression.Access.create "no_loop.b")
          {|
            no_loop.b.b: int = 1
          |};
        parse
          ~qualifier:(Expression.Access.create "no_loop.a")
          {|
            from no_loop.b import b as c
          |};
        parse
          ~qualifier:(Expression.Access.create "no_loop")
          {|
            from no_loop.a import c
          |};
      ]
  in
  assert_fixpoint_stop "loop.b" Type.Top;
  assert_fixpoint_stop "no_loop.c" Type.integer


let test_object_callables _ =
  let assert_resolved access annotation =
    assert_resolved
      [
        parse
          ~qualifier:(Expression.Access.create "module")
          {|
            _K = typing.TypeVar('_K')
            _V = typing.TypeVar('_V')
            _T = typing.TypeVar('_T')

            class module.Call(typing.Generic[_K, _V]):
              generic_callable: typing.Callable[[_K], _V]
              def __call__(self) -> _V: ...

            class module.Submodule(module.Call[_T, _T], typing.Generic[_T]):
              pass

            module.call: module.Call[int, str] = ...
            module.meta: typing.Type[module.Call[int, str]] = ...
            module.callable: typing.Callable[..., int][..., str] = ...
            module.submodule: module.Submodule[int] = ...
          |};
      ]
      access
      (Type.create ~aliases:(fun _ -> None) (parse_single_expression annotation))
  in

  assert_resolved "module.call" "module.Call[int, str]";
  assert_resolved "module.call.generic_callable" "typing.Callable[[int], str]";
  assert_resolved "module.call()" "$bottom";
  assert_resolved "module.callable()" "int";

  assert_resolved "module.meta" "typing.Type[module.Call[int, str]]";
  assert_resolved "module.meta()" "module.Call[$bottom, $bottom]";
  assert_resolved "module.submodule.generic_callable" "typing.Callable[[int], int]"


let test_callable_selection _ =
  let assert_resolved source access annotation =
    assert_resolved
      [parse source]
      access
      (Type.create ~aliases:(fun _ -> None) (parse_single_expression annotation))
  in

  assert_resolved "call: typing.Callable[[], int]" "call()" "int";
  assert_resolved "call: typing.Callable[[int], int]" "call()" "int"


let () =
  "access">:::[
    "fold">::test_fold;
    "module_exports">::test_module_exports;
    "object_callables">::test_object_callables;
    "callable_selection">::test_callable_selection;
  ]
  |> run_test_tt_main
