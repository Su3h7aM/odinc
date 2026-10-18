# Design of `check` and package loading

Status: implementation design. `check` owns Odin semantics; `driver` owns source discovery and build configuration; `types` owns canonical types and target layout; `lower` converts the checked program to the scalar Sea of Nodes IR in [02-ir-design.md](02-ir-design.md). This document does not introduce language features. Linux x64 is the first enabled target, not a different dialect. Other platforms' source and semantic metadata remain present.

## 1. Prior art, evidence and decisions

The prior-art check preceded this design. Reuse the existing `src/syntax` AST and parser, `src/types`, `support` source positions/diagnostics, `core:math/big`, `core:strings`, the path packages and `core:thread` facilities. `base/` and `core/` contain syntax tools but no complete semantic checker. The fork's `vendor/` contains bindings and support libraries, not a replacement checker. Do not copy a second parser, integer library or thread pool.

| Reference inspected | Reuse or constraint |
|---|---|
| `core/odin/doc-format/doc_format.odin:7-61,80-190` | Distinct file/package/entity/type indices, reserved sentinel entries, source positions and explicit entity/type records. Reuse vocabulary, not the little-endian serialized format as live checker storage. |
| [OLS `src/server/analysis.odin`](https://github.com/DanielGavin/ols/blob/master/src/server/analysis.odin), `AstContext`, `UsingStatement`, `CallArg`, `Candidate`, `resolve_base_symbol` | Scoped lookup state, explicit using/import provenance and candidate-local argument checking. OLS supports incomplete editor input and heuristic resolution. Its pointer-keyed recursion maps, fixed deferred depth and approximate type matching are not compiler semantics. |
| Fork `src/checker.cpp:8220`, `checker_global.cpp`, `check_*.cpp`, `entity.cpp`, `types.cpp` | Semantic ordering, dependency discovery, exact values, assignability, runtime roots and source diagnostics. Adapt the organization, not the mutable pointer AST or unity-build globals. |
| `/home/su3h7am/Projects/refs/Odin-upstream/src/{checker,check_type,exact_value}.cpp` | A second local source for staging and numeric representation; both local trees have integer/rational exact values. No separate reusable Odin checker was found in the reference tree. |
| [Ginger Bill's checker-stage reorganization](https://github.com/odin-lang/Odin/commit/67bedcba4b0f21497bc24f693d37840b3ddd5a65) | Published, authored staging evidence. The current fork's `check_parsed_files` is the detailed stage description; this historical commit is not the current stage list. |
| Official [overview](https://odin-lang.org/docs/overview/), [FAQ](https://odin-lang.org/docs/faq/), root `odin.ebnf` | Public language contract. Explicit procedure groups, lexical context, statement-based defer, constants, parametric polymorphism and no implicit general numeric conversions. |
| Official repositories [Odin](https://github.com/odin-lang/Odin), [examples](https://github.com/odin-lang/examples), [package documentation](https://github.com/odin-lang/pkg.odin-lang.org) | Existing language examples and the doc-format consumer, not alternative compiler implementations. Issue/PR searches found relevant failures and corrections below. |
| [Ginger Bill on errors](https://www.gingerbill.org/article/2018/09/05/exceptions---and-why-odin-will-never-have-them/), [language philosophy](https://www.gingerbill.org/article/2024/09/08/odin-weird-to-market/), [research/01](research/01-gingerbill-vision.md) | Errors are values, control flow is structural, and the compiler implementation must stay simple and efficient without changing Odin. No exception unwinder, arbitrary compile-time execution engine or new generic system. |

All unqualified C++ source citations below refer to `/home/su3h7am/Projects/Odin/src`, the fork revision recorded in [research/03](research/03-existing-compiler-map.md). Function names are the durable anchors when line numbers move. These are inspected source facts, not claims that a differential test has already passed.

Evidence decisions and apparent disagreements:

- The FAQ's short account of conversions is not an exhaustive assignability specification. `any`, union injection, procedure parameters and `#subtype` need the dedicated checker rules. [PR #6845](https://github.com/odin-lang/Odin/pull/6845) restricted transitive `#subtype` conversions, but Ginger Bill wrote on June 22, 2026, "I should not have merged this since it has fundamentally broken the functionality of `#subtype`", then supplied correction `67cd466`. Follow that corrected implementation and carry the selected field path to `lower`. Do not adopt the initial PR's restriction.
- The overview's inactive-`when` guarantee concerns semantic checking. `parser.cpp:6955-6995`, `parse_setup_file_when_stmt`, visits both arms for imports before `check_when_stmt` selects one. Preserve eager import discovery/path validation/parsing and skip inactive declarations' semantic checking. Do not promise that an invalid imported path inside `when false` is harmless. The import phase and semantic phase are separate.
- `defer` is not Go's eager argument capture or C++ destruction. The overview's example observes later changes to a variable. `check_stmt.cpp:2930` additionally rejects direct assignments to named results in a defer because returned values are already fixed. Preserve return-value capture before cleanup, and do not invent named-result mutation during cleanup.
- `ExactValue_Rational` and exact complex/quaternion components exist in both local compiler trees (`exact_value.cpp:15-84`). Use rational arithmetic for untyped float computations. Do not infer universal arbitrary-precision runtime floats from the overview's literal-conversion explanation; typed rounding follows the concrete checker operations.
- [Issue #2968](https://github.com/odin-lang/Odin/issues/2968) records missing RTTI in threaded polymorphic overload checking and a Ginger Bill fix. [Issue #6872](https://github.com/odin-lang/Odin/issues/6872) records nominal identity trouble inside polymorphic procedures. These justify isolated instance state and a deterministic commit point, not rejecting valid recursive calls or local types.
- [PR #7140](https://github.com/odin-lang/Odin/pull/7140), inspected as open work, concerns malformed polymorphic arguments. It is a regression source, not accepted design intent. Backend crashes on invalid input, including [issue #5015](https://github.com/odin-lang/Odin/issues/5015), are not behavior to reproduce. Diagnose unspecialized runtime types before `lower`.

Rejected alternatives: editing `Node_Payload` with semantic pointers breaks immutable parsing and instance isolation; translating the C++ checker line by line retains its global queues and locks; using OLS as the type checker accepts heuristic answers; checking every template body before substitution rejects valid `when` branches; concurrent allocation into one global type/entity store makes ordering depend on scheduling. None is required by Odin semantics.

## 2. Loading packages in `driver`

### Configuration and collection resolution

Freeze a `Build_Config` before discovery. It contains the target metrics, enabled target features, command/build mode, entry-point policy, runtime policy, test selection, defines, warning/vet/feature policies, collection roots and explicit allocators. The host OS does not decide `ODIN_OS`, integer size or file selection when a target is specified. Populate the compiler's builtin/config/intrinsics namespaces from this configuration before checking `when` or defaults.

Register `base`, `core` and `vendor` under the selected Odin root, which is this repository for our builds. Register each user `-collection:name=path` as a separate named root. There is no special implicit `user:` collection; that spelling works only if registered. Unqualified imports resolve relative to the importing source file's package directory, not the process working directory. Freeze the collection table, reject invalid/duplicate registrations according to the fork CLI, and never search other collections after a lookup fails. References: `build_settings.cpp`, `LibraryCollections`, `find_library_collection_path`; `parser.cpp`, `determine_path_from_string`; `path.cpp`, full-path normalization.

Validate the import string before joining paths. Match the fork's absolute-path prohibition for Odin package imports, reserved builtin-package names, collection errors, supported separators and deprecated `core:runtime`/`core:intrinsics`/`core:builtin` remapping to `base:` with its warning/vet behavior (`parser.cpp:6825-6940`). Preserve legal relative parent paths; do not add a sandbox policy. `system:` is only for foreign libraries, never Odin package search. Keep original spelling, normalized identity and display path separately so diagnostics do not depend on a worker's current directory. Resolve symlinks and path aliases with the same identity policy as the fork's path helpers, with conformance cases before enabling identity-based deduplication.

A package key is the normalized full directory identity plus the build configuration, not its declared name or import alias. Different aliases of the same directory share a package. Different directories with the same package name remain distinct inputs and receive the fork's eventual package-name validation. Builtin/config/intrinsics namespaces are compiler-provided; do not parse their documentation stubs as implementations. Seed the real `base:runtime`, the root package or `-file` input, extra packages and `core:testing` when required (`parse_packages`, `parser.cpp:7791`). Foreign libraries enter a separate manifest and are never treated as Odin packages.

### Discovery, file selection and deterministic parsing

1. Enumerate a package directory, normalize names, and sort eligible filenames by byte spelling before assigning file slots. Apply the fork's extension/name, OS/architecture suffix, test-file and command policies. A file's `#+build` tag is evaluated by the driver before semantic collection, with syntax support for reading leading tags.
2. Match `parse_build_tag` (`parser.cpp:7079`): comma-separated alternatives are OR; platform terms in an alternative are AND; `!` negates a term. Preserve `ignore`, subtargets, `bedrock` and invalid-platform diagnostics. Build tags are not Odin expressions and do not read arbitrary `-define` names. Multiple tag lines and filename filtering follow `process_imported_file`, not a new Boolean grammar.
3. Parse accepted files concurrently into private AST/source/diagnostic arenas. A worker returns a parsed file, leading file policies and a list of imports, including imports nested in both file-scope `when` arms. It cannot insert global entities or intern shared type handles.
4. Join a discovery round in sorted package/file order, deduplicate package requests, and repeat until the import closure is known. Cache failed requests so one missing directory does not cause unbounded duplicate work; retain import-site notes. Parse errors remain errors even when later semantics would ignore the file's package through a `when` arm.
5. Assign final package/file ordinals only after closure, using normalized package keys and sorted files. Diagnose import cycles with a stable source-ordered path; use dependency-before-importer topological order with the package key as the ready-queue tie-break. `check_import_entities` builds its graph before resolving global `when`; do not delete syntactic import edges merely because a branch will be inactive.
6. Remap provisional source references at the join. Entity source keys are `(package order, file order, byte offset, declaration subindex)`. Private allocation addresses, directory enumeration order, map iteration and task completion order never enter IDs, diagnostics, names or output tables.

The fork overlaps entity collection with parsing. v0 deliberately keeps a parse barrier because the AST is already compact and immutable. Package-local declaration scanning may later overlap parsing, provided its results remain provisional until the same ordered merge. Independent parse tasks use the existing thread-pool facilities; errors and allocation failures return as values and cancel outstanding work through the driver.

## 3. Checker data model

### Handles, storage and ownership

Use `distinct u32` handles for `Entity_Id`, `Scope_Id`, `Package_Id`, `File_Id`, `Instance_Id`, `Const_Id`, `Plan_Id` and `Symbol_Id`. Entry zero means none; a diagnosed invalid type is a real poison type, not the none handle. The owner has ruled that `types.Type_Id(0)` also means none. This replaces the initial types prototype's valid-zero convention. All tables, arenas and borrowed source lifetimes belong to one compilation; workers receive explicit scratch allocators. A zero checker owns nothing, and explicit destruction releases its owned arenas.

`Package` stores its key, declared name, ordered files/import edges, package scope, kind and phase state. `File` stores its package, source and immutable `syntax.Ast`, file scope, leading build/vet/feature policies and import declarations. Source bytes outlive constants that borrow literal text.

`Scope` stores its parent, kind, owner/source key, ordered declaration list, lookup map and using bindings. Kinds include universal, package, file, procedure, block and type-member scopes. Lookup maps answer questions only; ordered arrays drive every traversal. File imports/private-file declarations belong to file scope; package declarations are visible across its files; local variable visibility follows statement order. Handle forward-visible constants/types/procedures with the same block collection rules as `check_collect_entities`, without hoisting local variables. Do not allow a nested procedure to capture an enclosing runtime local. Labels have resolved branch targets and the fork's collision/visibility rules, not arbitrary expression values.

`Entity` has a name, kind, declaring scope/package/file, syntax reference, source key, flags, resolution state, `Type_Id`, optional `Const_Id`, declaration information and kind-specific payload. Kinds mirror `entity.cpp:7-20`: constant, variable, type name, procedure, procedure group, builtin, import name, library name, nil, label and assembly template. Using aliases retain their origin and field path rather than changing the original entity. Procedure data holds parameter/result entities, signature/defaults, body, attributes, calling convention, generic definition/instance, dependency lists and body state. Variable data distinguishes local/global/TLS, initializer and linkage. A type alias refers to the canonical underlying identity; a distinct declaration reserves a new nominal identity.

States are `Unresolved`, `Resolving`, `Resolved`, `Invalid`; bodies and nominal completion have separate states. Record the resolution stack and dependency edge kind so legal recursion through pointers/procedure signatures is distinct from constant, by-value layout and global-initialization cycles. Resolve mutually recursive procedures from signatures without waiting for their bodies. Never use a depth cutoff as the definition of a cycle.

### Immutable syntax and instance-local typed tables

`Node_Index` is local to an `Ast`, not a global expression key. The complete key is `(File_Id, Instance_Id, Node_Index)`. Instance zero denotes ordinary file semantics; a specialized procedure body owns another table view over the same syntax. Nested declarations also include the enclosing instance in their identity. An unroll iteration with different constant bindings needs its own semantic view, even though it is not a generic procedure instance.

```odin
Node_Ref :: struct {
    file: File_Id,
    node: syntax.Node_Index,
}
Typed_Nodes :: struct {
    types:     []types.Type_Id,
    constants: []Const_Id,
    modes:     []Addressing_Mode,
    entities:  []Entity_Id,
    plans:     []Plan_Id,
    scopes:    []Scope_Id,
    states:    []Node_State,
}
```

Each array is indexed by `Node_Index` and has `len(ast.nodes)` entries, including sentinel zero. This is a hand-written SoA, not a second syntax tree. Procedure-local views may allocate only the indexed span they own behind an accessor with a base index; do not allocate a whole file per tiny specialization. `Ast.extra` ranges and `Node_Payload` remain unchanged. A coverage test covers all 89 current node kinds and fails when the syntax enum changes without an explicit semantic classification.

Addressing modes preserve the distinctions needed by assignment and lowering: invalid, no value, value, immutable value, variable, constant, type, builtin, procedure group, map index, optional-ok/optional-ok-pointer, context, SoA variable and SoA pointer. Use the fork's `AddressingMode` rules, including mode changes on optional-result promotion. A bit-field projection is a checked place with a bit-access plan, not an ordinary addressable variable. There is no universal rule that every expression can produce a pointer.

`Node_State` distinguishes unseen, inactive, checked and invalid. Type-mode expressions record the represented type; runtime `typeid` values record type `typeid` plus a type constant. Literal/untyped categories belong to semantic typing and never become concrete runtime types accidentally. The final checked view contains concrete types at every runtime use, while unused/template/inactive syntax may remain untyped or unchecked.

Plans hold information not recoverable from one type handle: implicit conversions, member/using/subtype paths, optional-result shape, call argument ordering and default values, selected overload/instance, builtin operation, compound-literal field mapping, index/bounds policy, union operations and control exits. Plans refer to syntax nodes and constant/synthetic operands, not invented mutable syntax nodes. Probe candidates get scratch tables; failed overload attempts cannot mark an entity used, emit retained RTTI or overwrite the chosen expression type.

### Contract required from `types`

Use canonical `Type_Id` handles and target layout accessors, never C++ pointers. Structural interning does not erase named/distinct identity. The committed `types` interface is `reserve_nominal(store: ^Store, kind: Kind, name: string) -> Type_Id`, `complete_nominal(store: ^Store, id: Type_Id, descriptor: Type)` and `layout(store: ^Store, id: Type_Id, config := DEFAULT_LAYOUT) -> (size, alignment: i64, err: Layout_Error)`. Reservation accepts Struct, Union, Enum and Procedure. Completion asserts once-only use and matching kind/name, then seals the descriptor without changing its ID. The checker validates input before completion; layout returns Invalid_Type, Incomplete_Type or Recursive_Value rather than a successful zero-sized invalid record. A reserved identity may appear behind a pointer before completion, and layout states reject recursive by-value layout without rejecting recursive pointers.

`check` keeps generic patterns, parameter constraints, declarations, defaults, source member metadata, enum values, using/subtype flags and field tags. `types` keeps concrete identity, representation and layout. Extend its descriptors/accessors before callers need missing array indices, matrix dimensions/stride, bit-field widths/offsets/backing type, union form/tag and SoA details. Never rebuild layout formulas in the checker or hide semantic identity in a display name. ABI argument placement is a `types`/`lower` concern under IR design section 6; type checking validates calling conventions and parameter attributes.

## 4. Phases and barriers

Follow the fork's `check_parsed_files` staging, including the import subpipeline. Phases may demand-resolve dependencies, but that does not remove their commit barriers. The owner has confirmed serial semantic checking for v0, with parallel parsing and read-only validation only. The parallel column describes safe units once their inputs are frozen, including later semantic parallelism.

| Order | Work and publication barrier | Parallel work allowed |
|---|---|---|
| 0 | Freeze build config; create universal scalar types, compiler constants and builtin namespaces. Parse the complete import closure. | Private file parsing. |
| 1 | Map packages/files to scopes; collect unconditional declarations and pending global `when`/foreign sources. Export package entities provisionally. | File/package scans into private lists; ordered merge. |
| 2 | Build and order the import graph; install all file import bindings before evaluating any global `when`. Then resolve pending `when`/foreign declaration sources in package order. Match `check_import_entities:6687`. | Import validation against frozen export lists; selected-source publication stays ordered. |
| 3 | Correct aliases, gather global entities, finish export visibility; freeze package/file scopes. Merge queued entities by source key. Match `checker.cpp:8256-8294`. | Independent alias checks only after dependencies are known; v0 resolves serially. |
| 4 | `check_all_global_entities`: signatures, type declarations, constants and global initializers, using dependency groups. Run file-scope directives after globals. Sort late lazy entities. | Independent dependency components, with ordered commits; not concurrent mutation of shared types. |
| 5 | `init_preload`: bind and validate runtime `Type_Info`, allocator, `Context`, source-location and map declarations. Finalize pending global untyped uses. | Read-only schema verification after types complete. |
| 6 | Check eligible procedure bodies, nested procedures and demanded specializations to a fixed point. Resolve foreign import full paths; merge body-created entities. | Body workers only with frozen shared inputs and private semantic state. v0 is serial. |
| 7 | Add required basic RTTI types; validate deferred-procedure attributes and target-specific context providers; resolve global-variable link names. Build global-init graph nodes. | Read-only attribute checks and graph-edge construction. |
| 8 | Check scope usage, illegal type/inline cycles and global-init order. Generate the minimum dependency set after usage data exists. Collect demanded RTTI and verify all retained bodies were checked; validate test procedures. | Usage/cycle checks and init ordering can run concurrently as in `checker.cpp:8377-8417`; join before reachability-dependent publication. |
| 9 | Wait for all work; validate entry point; run enabled atomic/escape analyses and unique link/package-name checks; check instrumentation pairing. Finalize untyped expression values. | Read-only analyses with private diagnostics/dependency facts; ordered merge. |
| 10 | Canonical RTTI closure/hash/deduplication and table placement; sort init/fini procedures; validate entry-point intrinsics; freeze `Checked_Program`. | Hashing of frozen descriptors and validation scans; final table placement is serial. |

The fork starts RTTI hashing alongside later checks. We keep its logical inputs/order but may wait until phase 10 in v0. Scope freezing forbids new global names, not instance-local entities or local scopes. A declaration lazily checked by the fork stays lazy here; reachability does not excuse a missed error in a declaration the fork checks eagerly. Match body-root and lazy-selection rules in `check_procedure_bodies` and the minimum-dependency builder rather than treating all source bodies as roots.

For later semantic parallelism, workers receive frozen scope/type snapshots and return local entities, provisional type/instance requests, use/dependency events and diagnostics. A coordinator commits requests in `(origin source key, canonical argument key)` order, remaps provisional handles, then releases the next batch. A worker needing an unpublished result suspends that job; it cannot publish directly. Do not implement this machinery in v0 merely to claim parallel checking. Parsing, read-only validation and later `lower` function workers already offer independent parallel work.

Global initialization is dependency ordered, not alphabetical execution. Preserve dependencies through called procedures, constant-folded references where relevant and generated helpers. Reject cycles with an explicit path. Keep the fork's init/fini attribute priority and source-order tie-break rules in the final manifest.

## 5. Resolution, expressions and calls

Use explicit checker procedures with a small context record for the current scope, declaration, procedure/instance, expected type, allowed branch targets, active context and defer state. Save/restore lexical state at scope boundaries. Name resolution returns an entity or a diagnostic value; it never asks `lower` to resolve a string.

Check expressions with an expected type when one exists. Preserve untyped numbers, booleans, strings, runes, nil and uninitialized values until the consuming assignment/call/conversion fixes them. Apply representability checks there. Assignability and explicit cast/transmute are separate operations; distinguish aliases from distinct types, enum inference from numeric conversions, pointer/rawptr rules, union injection and `#subtype` paths. Assignment checks use the place mode and evaluate each destination/base/index exactly once. Simultaneous assignment plans retain the fork's evaluation and commit order.

Member lookup returns the actual field path, implicit dereferences and ambiguity/provenance. Promoted fields are not flattened into duplicate storage. An implicit selector such as `.Foo` uses its expected enum/union context. Map lookup and type assertions support optional-ok expansion only in the accepted use contexts. Multi-valued calls/tuple results are flattened according to `check_unpack_arguments`, not by treating all expressions as arbitrary tuples.

A call plan identifies a direct procedure/instance, indirect procedure value or builtin; provides ordered runtime arguments, expanded tuple projections, defaults and their evaluation sites, parameter conversions, variadic packing, result shape and context source. Named arguments select parameter positions without changing the fork's observable evaluation rules. Preserve `#caller_location`/`#caller_expression` defaults at the call site. Compile-time parameters never become ABI arguments. The plan records procedure attributes such as by-pointer, no-alias, no-capture and optional results for downstream checks and ABI planning.

Procedure groups are explicit `proc{...}` entities, not implicit overloads collected by identical names. Match `check_proc_group_decl` (`check_decl.cpp:1984`): resolve permitted procedure/procedure-variable members, evaluate member `where` filters, reject duplicates and group cycles, and report indistinguishable overloads without invalidating procedures used in other groups. Group expressions need a call or expected procedure type that selects a member. For calls, compare candidates with the fork's assignability distances, specialization rules and tie detection; source order stabilizes reporting, never breaks a semantic tie. Probe `where` failures quietly, then report the best relevant failures only when selection fails. Store the selected entity and instance so `lower` never repeats overload resolution.

`using` imports exported names, exposes enum members or creates aliases to fields of a struct variable/pointer according to `check_using_stmt_entity` (`check_stmt.cpp:779`). It is not allocation or cleanup. Check namespace collisions at insertion, preserve privacy and mutability, and retain the root variable plus complete field path. Struct/parameter `using` participates in member promotion; `#subtype` conversion is a separate relation, even where the same field has both flags. Do not mutate imported entities' using-parent fields globally. Using a constant/procedure/nil as a struct namespace remains an error under the fork's rules.

Bodyless foreign procedures still need parameter entities and checked defaults for direct calls. `expression_bodyless_signature_bindings` reuses the definition-side binder, including unnamed positional parameters, without requiring a body or changing the caller's result bindings. This follows `check_procedure_type` in the fork's `check_type.cpp`, where parameter metadata belongs to the signature. The foreign named/default/unnamed-parameter regression is checked separately from code generation.

Constant aliases of import names retain their `Import_Data` namespace, as `check_const_decl` in the fork's `check_decl.cpp` overrides an alias with `Entity_ImportName`. `_ :: intrinsics` marks a namespace reference without turning it into a runtime value. The checker regression uses two packages and verifies both type and constant member lookup through aliases.

The declaration at `base/intrinsics/intrinsics.odin:341` is `simd_extract`; repeated diagnostics at that location are not six distinct missing intrinsics. Its package declaration maps to `Builtin_Kind.Simd_Extract`. `check_builtin.cpp`'s `BuiltinProc_simd_extract` uses `check_index_value` and returns the vector element type. Our checker accepts runtime integer indices and rejects invalid vector/index operands and checked constant lane bounds. Lowering reuses the stack-backed SIMD representation and scalar indexed loads, consistent with the fork's direct `LLVMBuildExtractElement` in `llvm_backend_proc.cpp`, which adds no runtime bounds branch. Differential Mise checks accepted foreign calls and import aliases, and matched rejection of out-of-range, negative, fractional and nonvector extraction cases.

## 6. Constants and compile-time scope

A `Const_Id` names an immutable constant-pool value. Distinguish invalid, bool, arbitrary integer, rational, concrete float bits, exact-component complex/quaternion, UTF-8/UTF-16 string, nil, uninitialized, numeric pointer, procedure/entity reference, represented type, aggregate, union variant and assembly-template value. Some are accepted only in particular contexts. An aggregate stores a concrete type plus normalized fields/elements and a zero/default remainder, not a borrowed mutable C++ AST. Address-valued constant initializers retain symbol-plus-addend relocations separately from numeric pointer constants.

Use `core:math/big.Int` for untyped integers and `big.Rat` for exact fractions (`core/math/big/{api,rat}.odin`). They have explicit allocator/error plumbing. Constant results own arena-backed limbs, never alias a mutable scratch destination. Normalize fraction signs/denominators before equality or cache hashing. Literal parsing must produce exact integers and numerator/denominator values directly, including radix/exponent syntax; parsing to `f64` and then constructing a rational loses information. Reuse existing big-number parsing/arithmetic where applicable; write only missing Odin-literal normalization and target rounding adapters.

Typed floating operations round where `exact_value.cpp` and `check_expr.cpp` round, including f16/f32/f64, signed zero, non-finite intrinsic values and exact-component complex/quaternion conversions. Integer division/remainder, bitwise operations on negative arbitrary integers, shifts and target endian conversions use Odin's rules, not host arithmetic accidents. Check overflow/representability at typed boundaries and invalid dimensions before narrowing to layout integers. Constant overflow and division errors return diagnostics; they do not invoke runtime traps in the compiler. The four runtime integer-division-by-zero modes and per-file policies flow to checked operation plans as required by IR design section 8.

Untyped integer and decimal-fraction values remain exact (`big.Int` and normalized `big.Rat`); concrete typed floating values use the official compiler's f64-backed exact-value representation and its typed precision update. Evidence: fork `src/exact_value.cpp` defines exact rational numerator/denominator values, while upstream issue [#6590](https://github.com/odin-lang/Odin/issues/6590) records Ginger Bill's explanation that floats are stored as f64 and his authored fix [6087096](https://github.com/odin-lang/Odin/commit/608709693bb292a5d2624c9208d19b9e379e5553) updates precision for typed f16/f32 values (with f16 noted as not technically correct yet). Issue [#4225](https://github.com/odin-lang/Odin/issues/4225) and merged [PR #4226](https://github.com/odin-lang/Odin/pull/4226) document a float-to-integer representability failure, not a change to exact integer semantics. A scratch program run with the fork's compiler observed `0.1+0.2==0.3` true, `1.0/3.0*3.0==1.0` true, adjacent f64-range literals `9007199254740993.0==9007199254740992.0` false, and `9007199254740993==9007199254740993.0` true. Preserve this split: the rational pool is for untyped exact values; typed float storage/rounding remains in `Float_Value` and the numeric-conversion work.

Compile-time evaluation covers constant declarations/expressions, enum and bit-set values, array/matrix dimensions, default arguments, attributes, `where`, `when`, compile-time builtin/intrinsic queries and supported directives. Constant aggregates support only the indexing/slicing/construction operations permitted by the fork. The FAQ says named constants exist only at compile time and must become variables to be addressed or indexed with runtime indices. A readonly runtime global is a different entity.

There is no interpreter for arbitrary user procedures, compile-time I/O or a new `#run`. `#load` and related existing directives are explicit compiler operations, not general CTFE. Track their source/file dependencies in the driver for reproducible builds. Specialization and `#unroll` re-check syntax under constant bindings; they do not execute arbitrary procedure bodies. Cache constants only after their entity dependencies resolve, and retain cycle paths.

## 7. Polymorphism and monomorphization

Represent a polymorphic signature/record as a definition plus parameter patterns, defaults, specialization constraints and `where` expressions. It is not a completed concrete layout. Resolve `$T`, explicit `typeid` arguments, `$N` constant parameters and shape patterns using a substitution environment. Match fork `determine_type_from_polymorphic`, `check_record_polymorphic_params` and substitution/unification routines in `check_type.cpp`. Preserve named versus underlying types in specialization patterns; do not turn structural pattern matching into universal structural assignment.

Instance lookup uses `(definition Entity_Id, enclosing Instance_Id, ordered canonical arguments)`. Each argument is tagged as a type identity or a typed constant value; include inferred counts, defaulted parameters, procedure-valued constants and substitutions that affect the concrete signature/body. Equal aliases share canonical type arguments, while distinct types and nominal types declared inside different enclosing instances remain different. Numeric argument equality follows the parameter's checked type and constant semantics; a raw token spelling or an `f64` approximation is not a cache key. Hash tables accelerate lookup, but compare full keys on collisions.

Before checking a specialized body, reserve its instance/entity/signature and nominal result identities, then mark the instance `Checking`. Recursive requests for the same key refer to that reserved instance. `where` and all compile-time arguments must be valid before selecting it. Finish the concrete signature, publish it, check the body with a private typed view, record dependency/RTTI requests, then mark it `Complete` or `Invalid`. Reusing an invalid instance emits a concise use-site note, not its entire original diagnostic set. Different ever-growing instantiation keys are not a legal cycle shortcut; impose an explicit resource budget with a diagnostic and instantiation trace, distinct from semantic invalidity.

Templates are checked to the extent their declaration/signature requires before substitution. Dependent bodies and selected `when` arms are checked per concrete instance. Never share mutable expression modes, local entity IDs or inferred field mappings between instances. Generic record instances similarly complete one nominal identity per canonical key. No template or unspecialized type may reach a runtime symbol/layout/ABI slot.

Internal names derive from a stable qualified definition key, enclosing instance key and canonical argument encoding. Final enumeration sorts these keys; it does not number by first thread to request an instance. Escape/length-prefix names unambiguously; a digest is acceptable only with collision comparison and deterministic disambiguation. Exported/custom/foreign link names remain exactly the requested names under the fork's canonicalization rules. `-export-semantics`/diagnostic display names stay source-like and do not expose internal digest spelling.

The implemented record path in `src/check/type_instance.odin` reuses `Poly_Bindings`, typed constant interning, declaration-parent scopes and nominal reservation/completion. Its cache compares the declaration entity and ordered type/constant handles, never display strings. Each concrete record owns an instance-local expression view; this keeps field dimensions, alignments and `where` conditions independent between substitutions. Instances use the existing layout and RTTI descriptors. Display names follow the fork's `set_polymorphic_record_instantiation_name`, for example `Small_Array($N=3, $T=int)`. References are `check_type.cpp`'s `check_record_polymorphic_params`, `find_polymorphic_record_entity` and `set_polymorphic_record_instantiation_name`, `check_expr.cpp`'s `instantiate_polymorphic_record`, and upstream [issue #4380](https://github.com/odin-lang/Odin/issues/4380) for constant arguments in record constraints. The native `polymorphic_records` fixture was compiled through the official differential Mise task and exited with the expected value 127.

Follow-up: `record_type_name` still prints a kind label for unnamed descriptors outside its scalar, pointer, array, slice and map cases; extend it from the fork's `write_type_to_string` before claiming complete display-name compatibility. Cache identity does not depend on that text.

The fork's parser `is_ast_generic` does not traverse record-call arguments; its checker discovers polymorphic records while checking procedure types. Our parser `is_expr_generic` marks `Foo($T)` and named record arguments early because our checker defers generic procedure signatures and bodies. This is a staging difference, not a language change.

## 8. `context`, control exits and `defer`

### Context

`context` is a special lexical place of checked runtime type `runtime.Context`. Odin-convention procedures receive it implicitly; contextless/foreign-convention procedures do not. A procedure without an inherited context may explicitly assign `context = runtime.default_context()` before reading it or calling an Odin-convention procedure. Match `ScopeFlag_ContextDefined`, `check_expr.cpp:9878,13455`, and `check_procedure_type`. Do not silently synthesize a default context for such a call or for a global initializer.

Record the active context version/scope at each use and call. Assignment shadows or copies context for the current lexical scope according to the fork's context-copy rules; field writes also need the correct lexical context storage. Child scopes inherit the current context and restore the parent's view on exit. Match `lb_addr_store`'s context branch (`llvm_backend_general.cpp:1701`): retain old context storage once used, and copy on entry to a deeper modifying scope; unused same-scope storage may be reused. `lower` receives explicit context-place/call plans, copies or materializes context where required, and passes the pointer last under the Odin ABI. It must not implement this as one mutable process-global context pointer.

### Structured exits

Resolve every `return`, labeled/unlabeled `break`/`continue`, fallthrough, `or_return`, `or_break` and `or_continue` to a destination and lexical scope-exit list. Validate legal positions and procedure result types before forming plans. Return plans evaluate all return expressions and capture their values before cleanup. A bare return reads named result entities only when the signature permits it. Preserve switch/type-switch exhaustiveness, implicit case bindings and no-fallthrough rules. Record loop post destinations so a continue does not skip the post statement.

A `defer` registers a checked statement in its enclosing scope at the point reached. Execute reached defers in reverse order when structured control leaves that scope, including early-return propagation. Its expressions normally evaluate at execution time against the selected lexical bindings, not at registration. Record the active context-stack selection at registration: `lb_add_defer_node` saves its count (`llvm_backend_stmt.cpp:3694`), and `lb_build_defer_stmt:3610` restores that selection while generating the deferred statement. This is not eager argument evaluation or a deep snapshot of all referenced state. Do not execute a defer on a path that never reached its registration, on a scope not exited by a continue, or as an invented panic stack unwinder. Match `check_stmt.cpp:2930` and the fork's `lb_emit_defer_stmts`/`lb_close_scope` behavior cited by IR design section 8.

Check deferred statements in their declaration environment with defer restrictions: no deferred declarations, no return/`or_return` escaping the procedure from inside a defer, and the fork's legal branch restrictions. Direct assignments to named results in a defer receive the official diagnostic. Keep lexical defer registrations plus per-exit scopes in the checked form; `lower` expands cleanup and return-value capture into explicit control/effect edges. Attribute-driven deferred procedures (`@(deferred_in)`, `deferred_out`, related variants) are a separate validated call-plan feature, not syntax `defer`; their captured input/output arguments must follow `check_deferred_procedures`.

### Early propagation

For `or_return`, first check the operand once, then split off its final value or promoted optional-ok value (`check_or_return_split_types`, `check_builtin.cpp:138`). A boolean succeeds when true; a nil-capable value succeeds when nil. Failure yields the final value to the enclosing procedure's last result, with the fork's special conversion between boolean types. The preceding values form the successful expression's value/tuple or no-value result.

The enclosing procedure must have a last result assignable from the failure value. If it has several results, they must be named; their current values supply the other returned results. Record the optional-result promotion, test kind, projections, failure conversion and return exit plan. `or_return` is illegal outside a procedure or inside a defer (`check_or_return_expr`, `check_expr.cpp:11168`). Treat related `or_else`/branch forms with the same split/test logic, but their own destination and fallback evaluation rules. `lower` receives the complete decision; it does not guess that every propagation operand is a two-result `(value, bool)` call.

## 9. `when`, foreign declarations, attributes and directives

File build tags are a driver concern; `when` is Odin constant checking. Require a constant boolean, check only the selected statement/declaration list in the surrounding scope, and record the selected arm. A `when` arm does not introduce an extra ordinary block scope (`check_when_stmt`, `check_stmt.cpp:702`). Global `when` sources may reveal declarations and more dependencies, so phase 2 resolves them before scope freezing; imports already exist in every file. A dependent procedure `when` waits for its instance bindings. Detect constant/declaration dependency cycles without evaluating the other arm to break them.

Foreign imports create library entities with ordered input paths, collection provenance and source positions. Foreign blocks provide inherited library/default calling convention, export/link-prefix/suffix and attribute settings, then restore the outer settings on exit. Check bodies, initializers, symbol types, variadics, calling conventions and link-name uniqueness under `check_decl.cpp` and `foreign_block_decl_attribute` (`checker.cpp:4293`). Foreign declarations are typed externs, not automatically executable intrinsics. Default Odin versus contextless/C calling conventions remain distinct.

On Linux the compiler's own runtime and standard-library path use kernel syscalls and no third-party C runtime. The checker must nevertheless model valid user foreign declarations; initial inability to link an external C library is a driver/link capability error, not a new Odin type restriction. Keep first-party system-library metadata for other platforms. Foreign path existence/fullpath diagnostics occur at the fork's phase, after procedure checking where applicable. The [IR open-question rulings](02-ir-design.md#open-question-rulings) settle runtime assembly imports: recognize the runtime stubs as compiler-emitted entry/TLS/stack-protector sequences; user assembly imports remain later work.

Attributes are typed declaration metadata with declaration-specific validators, constant values, duplicate detection, legality and inheritance. Preserve procedure attributes for export/linkage, inlining/optimization, required results, test/init/fini/disabled/deferred behavior, instrumentation and platform bindings; variable attributes for thread-local storage/linkage/sections/alignment; visibility/deprecation and user tags. Unknown attributes are errors unless `-ignore-unknown-attributes` or `-custom-attribute` permits them (`checker.cpp:5275-5305`). Permitted custom attributes remain available to semantic/doc output; they do not gain code-generation effects.

Use one builtin/directive identity inventory with argument counts, allowed contexts and result categories; put semantic procedures beside each family. The fork's `checker_builtin_procs.hpp` and `check_builtin.cpp` are the completeness checklist, not a proposal for one giant switch. Cover:

| Family | Checked result and responsibility |
|---|---|
| Type/value queries and conversion builtins | Constants where specified (`size_of`, `align_of`, `offset_of`, `type_of`, `typeid_of`, `type_info_of`, `len`, `cap`, type predicates); otherwise a typed operation. Do not assume every query is constant for every operand. |
| `#assert`, `#panic`, `#defined`, `#config` | Constant diagnostics/configuration; honor name-query rules without resolving an undefined name as an ordinary use. Run non-declaring file directives after globals. |
| Source/caller and load directives | Source-location/expression defaults, procedure references and loaded data with explicit dependency records. Preserve accepted arguments, compile-time restrictions and file-origin rules. |
| Bounds/type-assert/optimization directives | Validate placement and attach effective flags/policies to the checked operation, never alter syntax flags after parsing. |
| Allocation, map, dynamic-array and string builtins | Checked operand/mutability rules plus concrete runtime-helper dependencies. Lowering expands operations, not name lookup. |
| Atomics, SIMD, CPU, overflow and other intrinsics | Concrete operand/result types, lane/order/immediate constraints, target support and operation identity. Optional target/backend support is separate from whether the Odin program is well typed. |
| `#unroll`, asm templates and target-specific declarations | Explicit expansion bindings or validated metadata. Do not let unsupported backend cases fall through as ordinary procedure calls. |

## 10. Special types and runtime identity

| Feature | Checker result consumed downstream |
|---|---|
| `#soa` | Concrete fixed/slice/dynamic SoA descriptor, logical element type, generated storage-field mapping and pseudo-place modes. Validate source element kind and field restrictions, indexed projections and SoA pointer operations using `complete_soa_type` and array checking. No array-of-struct pointer alias for a split field layout. |
| `#simd` | Concrete element/count descriptor; power-of-two count and fork maximum, valid integer/float/boolean/rawptr elements without explicit endian variants (`check_type.cpp:4984-5009`). Record lane/broadcast/shuffle constraints and intrinsic identities. Scalarization in `lower` does not change semantic vector types. |
| Matrix | Concrete element, row/column dimensions, row-major flag and target stride/layout. Match `check_matrix_type:4519`, its minimum/maximum and overflow checks; supported elements include integer, float and complex. Check multiplication dimensions and distinguish matrix multiplication from elementwise operations. No host-vector-layout assumption. |
| `bit_field` | Concrete integer or integer-array backing type; named field types, widths, bit offsets and tags. Fields are typed integers/enums/booleans with the fork's size/width limits. Validate backing capacity after generic substitution (`check_bit_field_type:1175`). Selection is a bit-access plan for extract/update, not a byte field address. Honor backing endianness. |
| `bit_set` | Enum/range domain, lower/upper bounds and explicit/default backing type (`check_bit_set_type:1511`). Explicit backing permits an integer or integer array; it forces a positive lower bound to zero and forbids a negative lower bound. Default backing uses the inferred domain span with the fork's 128-bit limit. Validate fit, duplicates, membership, set operators and implicit selectors. Carry the effective domain offset; enum values are not necessarily zero-based bit positions. |
| Union | Canonical variant identities, shared/no-nil form, layout/tag descriptor, injection and assertion/type-switch plans. Preserve pointer-maybe optimizations only through the type layout contract; do not assume all unions store a byte tag. |
| `any` | Data pointer and runtime typeid representation with checked boxing/unboxing/assertion plans. Boxing a value needs correctly scoped materialized storage; it is not an implicit heap allocation or a numeric cast. Mark its concrete type and transitive RTTI dependency. |
| `typeid` | Semantic type identity or runtime identity operation, distinct from compiler `Type_Id`. Named/distinct types and specialized local nominal declarations remain distinguishable. Do not embed compiler handle numbers in generated objects. |

Represent checked operation requirements independently of which backend currently implements them. Unsupported code generation returns a source-positioned capability diagnostic before IR construction. Do not reinterpret well-typed matrices as arrays, turn SIMD predicates into scalar booleans or drop reflection information to make an early milestone pass.

## 11. Runtime schema and RTTI

Bind runtime schemas from checked `base:runtime` declarations, then verify the expected structure before checking bodies that depend on them. `init_preload` (`checker.cpp:4205`) binds `Type_Info`, allocator, `Context`, `Source_Code_Location`, map records and target-specific runtime types. `init_core_map_type:4067` specifically binds `Map_Info`, `Map_Cell_Info` and `Raw_Map`; generated concrete map metadata refers to these checked types. Do not maintain unrelated compiler copies of their Odin layouts. Runtime schemas can use compiler-provided intrinsics/types during bootstrap, but cannot depend on a completed RTTI table. Respect the runtime's `type_info_of` preload restriction (`check_builtin.cpp:3598`), rather than hiding a circular bootstrap dependency.

The compiler instantiates descriptors, not new language declarations for `Type_Info_*`. Preserve the exact variant order and fields in `base/runtime/core.odin:94-294`. Required descriptor kinds are Named, Integer, Rune, Float, Complex, Quaternion, String (including encoding/cstring), Boolean, Any, Type_Id, Pointer, Multi_Pointer, Procedure, Array, Enumerated_Array, Dynamic_Array, Slice, Parameters, Struct, Union, Enum, Map, Bit_Set, Simd_Vector, Matrix, Soa_Pointer, Bit_Field and Fixed_Capacity_Dynamic_Array. Procedure parameter/result tuples use `Type_Info_Parameters`, not an invented general runtime tuple kind.

Collect requirements while checking, scoped to the owning declaration/instance. Retain the closure for the minimum dependency set, plus the fork's required basic types. Include types used by boxing, type assertions/type switches, `typeid_of`/`type_info_of`, reflection, map keys/values and generated helpers. Descend through named bases, elements, pointer targets, fields, variants, procedure parameters/results, enum/backing types, map representations and SoA support types. Use a visited set to terminate recursive types. Typeid-only uses under `-no-rtti` still need valid identities; reflection queries and forbidden operations receive the fork's diagnostics rather than silently returning nil descriptors.

The frozen RTTI plan contains runtime IDs, table slots, size/alignment/flags, all variant payloads and descriptor references. It also contains field names/types/offsets/usings/tags, enum names/values, union tag information, matrix dimensions/stride, SoA metadata, bit-field widths/offsets, procedure names and calling convention, map `Map_Info`/cell information and equality/hasher symbol requests. Struct/union comparison helpers must exist when descriptor flags require them. Anonymous procedure tuples need stable identity handling without merging distinct nominal types.

For v0 preserve the fork's canonical numeric typeid algorithm (`name_canonicalization.cpp:586`), including nominal package/declaration/instance identity, with full identity checks for collisions. This is the owner's initial compatibility choice, not a permanent numeric-ID requirement: the [IR open-question ruling](02-ir-design.md#open-question-rulings) requires only consistency with our generated type table, so we may drop the fork's algorithm later. Sort hash/type keys before deterministic table placement, reserve slot zero and use the probing/`__type_info_of` contract in `check_parsed_files:8470` and `base:runtime`. Distinct types with an identical runtime hash must produce a compiler-limitation diagnostic before lowering, not silently share a descriptor or reproduce the fork's internal panic. Do not substitute random hashes or discovery ordinals.

`lower` materializes descriptors, payload/name/offset/tag arrays, descriptor relocations, runtime `type_table` and helper bodies from this plan. It must not emit a descriptor for every type ever interned. The checker supplies required roots such as `Type_Info`, `type_table`, `__type_info_of`, bounds/assertion helpers, allocator/context startup and reachable operation helpers (`generate_minimum_dependency_set`, including `checker.cpp:3531-3575`). Runtime-call dependencies are explicit so reachability cannot discard a helper first discovered by lowering.

## 12. Exact boundary to `lower`

`check` imports `syntax`, `types` and `support`, not `ir`. `lower` imports all three plus `check` and `ir`. Extend the architecture package table accordingly; no `check`-to-`ir` cycle. A successful check returns an immutable `Checked_Program`; a failed check returns diagnostics and no lowerable program. The checked form is the original AST plus typed tables and semantic plans, not a CFG and not a second desugared syntax AST.

`src/check/model.odin` defines the borrowing record/accessor contract below. The caller owns all slices, maps, source buffers and the type store and must keep them valid and unchanged through lowering. Handle-indexed tables reserve entry zero; ordered procedure/global lists do not. `Typed_View.first_node` permits compact procedure spans, and `expression_info` returns `(Expression_Info, ok)` with `#optional_ok`; `ok` means the indexed row exists, while `Expression_Info.state` distinguishes checked/inactive/invalid rows. No accessor allocates or mutates the AST. `plan` and `constant` return nil for absent handles; `entity_symbol` returns zero when the entity has no mapping. Detailed checking and constant/plan construction remain the later tickets.

| Interface | Exact content/guarantee |
|---|---|
| `check.procedures(program)` | Ordered `Checked_Procedure` list for retained concrete bodies, concrete generic instances, nested noncapturing procedures and requested compiler-generated helper bodies. Each has entity/symbol IDs, complete semantic signature, body `Node_Ref` or generated-body recipe, typed-view ID, parameter/result entities, calling convention, attributes and source location. Extern declarations are symbols, not empty bodies in this list. |
| `check.expression_info(program, view, node)` | Final represented/value `Type_Id`, `Const_Id`, addressing mode, selected entity, validity and plan handle. Lookup never triggers checking, layout completion or instantiation. |
| `check.plan(program, plan)` | Typed tagged record for conversions, checked places/member paths, calls/argument evaluation, builtins, aggregates, bounds, unions, early propagation or control exits. Auxiliary slices are immutable and carry concrete type/entity references. |
| `check.symbols(program)` and `check.entity_symbol(program, entity)` | Ordered function/global/extern symbol declarations plus direct entity-to-symbol mapping. Aliases map to the target; local variables/compile-time-only entities have no module symbol. Symbols carry final link name, linkage/visibility, type, TLS/section/alignment and foreign-library provenance. `Symbol_Id` is checker-owned; `lower` predeclares matching IR symbols and records the mapping. |
| `check.globals(program)` | Ordered storage declarations, target types, alignment/TLS, constant initializer values and relocations or a `Global.dynamic_initializer` plan handle. A shared multi-variable initializer is one assignment plan and executes once, not once per result. Separate dependency-ordered global initialization and init/fini procedure lists, including priorities. No map iteration to choose initialization order. |
| `check.constants(program)` | Immutable values with exact numeric content; concretely typed use sites include the final rounded/bounded value. Procedure/type constants resolve through the symbol/runtime-ID maps. |
| `check.type_store(program)` | Frozen complete concrete type store and target layout accessors. No unresolved by-value layout, template parameter or provisional handle in a retained runtime use. Check-only patterns remain inaccessible to layout/ABI queries. |
| `check.runtime_requirements(program)` | Bound runtime-schema entities, validated operation/helper dependencies, generated equality/hash/map helpers, entry/test/startup metadata and exact RTTI plan from section 11. All helper symbol declarations exist before function lowering starts. |
| `check.sources(program)` | Source spans, effective per-file/per-operation policies and instantiation origin chains for debug information and capability diagnostics. Paths and positions remain stable for the lifetime of lowering. |

Final order is dependency-before-importer package order, source order within ordinary entities, then canonical instance/generated-helper keys. Calls may refer forward through symbol IDs. `lower` declares every function/global/extern symbol in this order before parallel function workers begin, as IR design sections 3 and 14 require. Per-function generated blobs/signatures stay local and merge in function order; workers cannot discover and append new module symbols.

`lower` owns control/effect graph creation, evaluation-order sequencing, defer expansion, context copies, runtime helper calls, bounds/assert checks, aggregate storage/copies, ABI plans and concrete argument/result packing. It expands i128/u128 to I64 pairs, honors f16 rounding and scalarizes supported SIMD operations as IR design requires. It emits no new name resolution, overload search, generic inference, constant evaluation or type-layout policy. An unhandled retained plan is an explicit implementation error/capability result, never a fallback reinterpretation.

A boundary verifier rejects missing expression facts on reachable syntax, unresolved symbols/types/instances, incomplete call/exit plans, dangling ranges and missing runtime/RTTI helper declarations. Selected `when` arms only are reachable; declaration/template nodes need explicit classifications, not fabricated runtime types. The verifier runs before any IR graph worker, then each graph passes the IR verifier.

## 13. Diagnostics and failure handling

Diagnostics are values containing severity/code, primary source span, message arguments, ordered related spans/notes, instantiation chain and source-order key. Resolve byte positions through `support` source records to the fork's line/column conventions; do not lose the original use-site span during substitution. Worker errors return to the coordinator. Only `driver` formats text/JSON, applies output policy and chooses process exit status. Allocation failures and internal failures are separate typed results, not source type errors or `panic` in normal recovery.

The fork defaults to 36 errors (`build_settings.cpp:11,736`). `error_va` increments the primary error count and stops when it exceeds the configured limit before appending the triggering diagnostic (`error.cpp:755-766`). Nonpositive internal values select the default; they do not mean unlimited. Held/muted candidate diagnostics do not consume the committed primary-error budget. Warnings do not consume it unless promoted by `-warnings-as-errors`; related note lines are not independent primary errors. Preserve duplicate suppression from `push_error_value`/collector behavior, rather than deduplicating unrelated diagnostics just because they share a line.

Our coordinator commits primary diagnostics in deterministic phase/source order and retains at most the configured count. On the next error it marks the limit reached, stops semantic publication and cancels remaining work. Unreported candidate failures stay discarded; related notes stay attached to retained primaries. Exact text/JSON formatting and duplicate-count edge cases get differential fixtures. The fork's concurrent race over which errors reach the limit is an observed implementation detail, not a deterministic ordering contract to emulate.

Recovery uses invalid entities/types/values to suppress derivative failures while continuing independent declarations. Do not let a poison type satisfy `where`, select an overload, produce a valid layout or enter a successful checked program. A resource-limit diagnostic carries the dependency/instance trace. Completion/cancellation always joins workers and releases scratch arenas before returning.

## 14. Implementation tickets and dependency graph

Estimates include tests and error paths, with at most about 600 changed Odin lines per ticket. File names are proposed ownership boundaries. Freeze each predecessor's interface before assigning dependent tickets. Do not turn a row into a package-wide rewrite; split it again if measured changes exceed the estimate. Full builtin and attribute inventories require additional same-size family tickets, not one hidden catch-all implementation.

| Ticket | Deliverable and owned file(s) | Lines | Needs |
|---|---|---:|---|
| C0 | Handles, records and checked-view accessors, `check/model.odin` | 450 | syntax/types handle contracts |
| C1 | Entity/scope storage, lexical lookup, `check/scopes.odin` | 500 | C0 |
| C2 | Declaration collection/visibility, `check/collect.odin` | 550 | C1 |
| D0 | Frozen config/collection resolution, `driver/collections.odin` | 450 | support |
| D1 | File/name/build-tag filtering, `driver/file_selection.odin` | 500 | D0, syntax leading tags |
| D2 | Parallel parse results and ordered discovery rounds, `driver/load.odin` | 550 | D1, syntax parser |
| D3 | Import graph/cycles, stable ordinals/remap, `driver/import_graph.odin` | 500 | D2 |
| C3 | File imports and pending `when` sources, `check/imports.odin` | 550 | C2, D3, N2 |
| N0 | Integer/rational constant pool and keys, `check/constants.odin` | 450 | C0, core:math/big |
| N1 | Exact Odin numeric literal normalization, `check/literals.odin` | 550 | N0 |
| N2 | Constant operators, comparisons and boolean conditions, `check/constant_ops.odin` | 550 | N1 |
| N3 | Typed numeric conversion/rounding boundaries, `check/numeric_conversion.odin` | 550 | N2, types scalars |
| N4 | Aggregate/string/type/procedure constants, `check/constant_values.odin` | 500 | N2, T1 |
| T0 | Declaration resolver, dependency/cycle states, `check/resolve.odin` | 500 | C2 |
| T1 | Concrete type expressions/nominal completion, `check/type_expr.odin` | 550 | T0, N2, types reservation/layout |
| T2 | Assignability, casts and transmute, `check/conversion.odin` | 550 | T1, N3 |
| E0 | Identifiers, unary/binary expressions and type hints, `check/expr.odin` | 550 | T2 |
| E1 | Selectors, promotion and using/subtype paths, `check/select.odin` | 550 | E0 |
| E2 | Index/slice/map/optional-place checking, `check/index.odin` | 550 | E0, N2 |
| E3 | Compound literals/default field mapping, `check/compound.odin` | 550 | E1, N4 |
| P0 | Procedure signatures/defaults/results, `check/signatures.odin` | 550 | T1, T2 |
| P1 | Calls, named args, tuple/variadic mapping, `check/calls.odin` | 550 | P0, E0 |
| P2 | Explicit groups/candidate ranking, `check/groups.odin` | 550 | P1 |
| G0 | Generic parameter patterns and substitution keys, `check/poly_patterns.odin` | 550 | P0, N0 |
| G1 | Unification/specialization/where probes, `check/poly_match.odin` | 550 | G0, E0, N2 |
| G2 | Instance reservation/cache and record completion, `check/instances.odin` | 550 | G1, T1 |
| G3 | Instance-local typed views/nested identities and worklist, `check/instance_bodies.odin` | 500 | G2, S2 |
| S0 | Assignment/return expression plans and locals, `check/assignment.odin` | 500 | E1, E2, P1 |
| S1 | If/loop/branch targets and scope exits, `check/control.odin` | 550 | S0 |
| S2 | Procedure body driver, context and syntax defer, `check/bodies.odin` | 550 | S1, P0 |
| S3 | Value/type switches, coverage and case bindings, `check/switch.odin` | 550 | S1, R0 |
| S4 | Propagation/or_else/or-branch plans, `check/propagation.odin` | 450 | S2, E2 |
| S5 | Unroll binding views and branch rules, `check/unroll.odin` | 500 | S1, N2, G2 |
| A0 | Constant attribute validation/foreign inheritance, `check/attributes.odin` | 500 | P0, N2 |
| A1 | Linkage/foreign entities and manifests, `check/foreign.odin` | 550 | A0, D0 |
| A2 | Deferred procedures/init/fini/test/instrumentation validators, `check/proc_attributes.odin` | 550 | A0, S2 |
| B0 | Builtin inventory, type queries/config/source directives, `check/builtins.odin` | 550 | T1, N2 |
| B1 | Memory/container builtin checks/dependencies, `check/builtin_memory.odin` | 550 | P1, E2 |
| B2 | Numeric/overflow/bit builtin checks, `check/builtin_numeric.odin` | 500 | N3, P1 |
| B3 | Atomic constraints and dependency records, `check/builtin_atomic.odin` | 500 | P1, T2 |
| B4 | Runtime-used target/SIMD intrinsic family, `check/builtin_target.odin` | 550 | V1, P1 |
| R0 | Union/any/typeid/assertion/type-switch plans, `check/runtime_values.odin` | 550 | T1, E0 |
| V0 | SoA completion/logical field plans, `check/soa.odin` | 550 | E1, T1, types SoA layout |
| V1 | SIMD/matrix type/operator constraints, `check/vectors.odin` | 550 | E0, T1, types vector layout |
| V2 | Bit-field/bit-set checking and access plans, `check/bits.odin` | 550 | E1, N2, types bit layout |
| R1 | Runtime schema binding/validation, `check/preload.odin` | 450 | C3, T1 |
| R2 | RTTI closure/payload descriptions, `check/type_info.odin` | 550 | R1, R0, V0-V2 |
| R3 | Canonical identity/hash/table placement, `check/type_ids.odin` | 500 | R2, G2 |
| R4 | Equality/hasher/map helper declarations/recipes, `check/helpers.odin` | 550 | R2, B1 |
| F0 | Reachability/runtime roots and body completeness, `check/dependencies.odin` | 550 | G3, B0-B4, A2, R1 |
| F1 | Global-init ordering and link/package collisions, `check/globals.odin` | 550 | F0, A1 |
| F2 | Scope usage/type-inline cycles and analysis facts, `check/usage.odin` | 550 | F0 |
| F3 | Diagnostic ordering/limits/candidate recovery, `check/diagnostics.odin` | 450 | C0, support diagnostics |
| F4 | Phase coordinator/frozen boundary verifier, `check/check.odin` | 550 | C3-F3 as applicable |
| Q0 | Differential corpus runner script under Mise, `scripts/conformance` | 400 | D2, F3, existing scripts |

The dependency graph has four independent roots: C0/C1/C2/T0, D0/D1/D2/D3, N0/N1/N2/N3 and F3. T1 joins collection and constants; P0 and E0 branch from typing. Statement checking and generic matching then proceed independently until G3. Runtime schema validation begins after globals, while R2-R4 follow concrete special types. F0/F1/F2 and F4 join the completed semantics; Q0 can be developed against fixtures earlier and runs real comparisons once F4 exists. Do not serialize all work behind loading if a ticket can test hand-built syntax inputs.

Safe initial agent ownership after C0: one owns `scopes/collect/resolve`, one owns driver files, one owns numeric files, one owns diagnostics. After T1: separate owners for signatures/calls/groups, expression/place files, generic files and runtime/special-type files. After S0: one owns control/bodies/propagation while another owns switches/unroll. Assign header/accessor changes through the model owner. No two agents edit the same file; shared types/support changes are separate prerequisite tickets owned by those packages. Semantic execution is serial in v0 even though development is parallel.

## 15. Conformance, milestones and risks

Add the differential runner as an executable Bash task with `#MISE` headers, following `scripts/_lib.sh`, rather than invoking compiler commands outside Mise. Both compilers receive identical source, collection roots, target/defines, vet/feature policies and test selection. Record fork version/revision and command arguments. The runner must not overwrite or relabel expected failures to get a passing count.

Start with the fork's `/home/su3h7am/Projects/Odin/tests/{internal,issues,core}`, then each enabled target's package `tests/` directories in the fork. `internal/test_rtti.odin`, `internal/test_simd.odin`, `core/odin/test_parser.odin`, `core/fmt/test_core_fmt.odin` and issue reproducers cover behavior beyond hand-written microtests. Follow the fork test runner's defines and package boundaries; do not compile every directory as a default executable. Classify target-inapplicable, harness-only and not-yet-implemented cases explicitly. A test unavailable on Linux x64 is not a checker failure and not evidence of support on another target.

Compare check acceptance first, then primary diagnostic severity/message/span and related notes with a high error limit to avoid truncation hiding mismatches. Normalize only output paths/terminal styling and documented presentation differences. Keep expected divergences in an explicit evidence-linked manifest, particularly fork-only features versus public upstream behavior. Do not normalize away wrong names, offsets, candidate ordering or missing notes. Separately compare exit status/limit behavior at 1 and 36 errors, warning promotion and candidate suppression.

Once lowering runs, execute the same passing tests and compare observable values/output and reflection structure, not internal addresses. Verify every runtime `typeid` resolves to the matching descriptor; compare numeric IDs too while the canonical-hash compatibility decision remains unchanged. Rebuild with one and several parse workers, varied directory enumeration and instance request orders; typed dumps, diagnostics, symbol lists, init order, RTTI tables and object bytes must be identical. Keep a deterministic checked-program dump as the primary debugging artifact. Use LLDB only through a delegated investigation if a compiler crash needs debugging.

Meaningful focused cases fill corpus gaps: recursive nominal identity and invalid by-value cycles; one generic body checked at different types and nested local nominal types; ambiguous group probes without leaked dependencies; two-phase using/subtype paths; inactive-when imports versus inactive type errors; context changes observed by a deferred call; early propagation across loop/defer scopes; named result capture; RTTI/hash collisions and complete map/union descriptors. Prefer one high-level case that exposes several interactions to a test per helper.

Milestones:

- M0 checks the existing compiler packages and targeted language fixtures, including diagnostics and phase dumps, without claiming to compile the runtime.
- M1 checks `base:runtime` and its complete Linux x64 import closure. This needs preload-safe type queries, explicit calling conventions, recursive records, constants/when/attributes/foreign manifests, TLS, context, generics, using, maps/arrays, unions, atomics, overflow and runtime-used SIMD/CPU intrinsics. It cannot be reached by turning off RTTI/TLS or changing standard-library declarations.
- M2 checks `core:fmt` and its import closure with normal runtime options. This adds broad reflection descriptors, varargs/defaults and explicit groups, nested polymorphism, exact complex/quaternion/i128/f16 behavior, enumerated arrays, bit sets and container helpers. `fmt` is not a small integer-only demonstration.
- M3 feeds the verified checked form to `lower` and runs the conformance corpus. Integration implements direct entry/TLS/stack-protector emission and SIMD scalarization under the [IR open-question rulings](02-ir-design.md#open-question-rulings).

The main risks are hidden dependencies discovered after symbol freezing, generic instance identity leaks, exact-number rounding mismatches, invalid recovery reaching layout, incomplete runtime schemas and trying to enable parallel semantics before deterministic publication exists. Track memory per checked node/instance, instantiation counts and phase times using real runtime/fmt inputs; do not add speculative caches before those measurements.

Defer for v0: incremental/daemon checking, cross-build cache serialization, semantic mutation across worker threads, arbitrary CTFE, richer tooling/export formats and performance-only native SIMD lowering. Other-platform backend enablement, advanced user-library linking and target-specific intrinsic lowering can follow Linux x64, but their valid syntax/type metadata must not be removed. Additional builtin/attribute families outside M1/M2 are scheduled in bounded tickets with explicit capability failures until implemented; this is an implementation milestone, not a reduced Odin specification. Escape/atomic analyses used by enabled language checks, deferred procedures, ordinary `#simd` semantics and RTTI are not optional merely because they are difficult.

## 16. Owner rulings

1. Semantic checking is serial in v0. Parsing and read-only validation may run in parallel.
2. Preserve the fork's canonical numeric typeid algorithm initially as a low-cost compatibility default. Only table consistency is required, so the numeric algorithm may change later.
3. Use the committed `types.reserve_nominal`, `types.complete_nominal` and `types.layout` signatures in section 3. Checker model and checked-view accessors live in `src/check/model.odin`; detailed semantic algorithms remain separate tickets.
4. The [IR open-question rulings](02-ir-design.md#open-question-rulings) settle baseline SIMD and startup: `lower` scalarizes SIMD without changing the runtime; the compiler emits entry/TLS/stack-protector sequences directly; user assembly imports are later work; `__ODIN_LLVM_F16_SUPPORTED` is false while the language's f16 type stays unchanged.

## Appendix A. Polymorphism implementation note (agent-500)

Official references, read before this note: `/home/su3h7am/Projects/Odin/src/check_type.cpp` `determine_type_from_polymorphic` (~2874, untyped/compound-literal sources first, then unification), `check_record_polymorphic_params` (~395), `check_procedure_type` (~4026); `/home/su3h7am/Projects/Odin/src/check_expr.cpp` `find_or_generate_polymorphic_procedure` (~719, instance cache and body check), `find_or_generate_polymorphic_procedure_from_parameters` (~1131), the call site (~7581) and `evaluate_where_clauses` (~7776). Nothing here is copied; the cache key and the reserve-then-check order follow section 7.

Current state: `procedure_type` (type_expr.odin) rejects `signature.generic`, and records reject `poly_params` and `where_clauses`. The expression checker has no instantiation. The M1 gap is therefore the whole feature, not a field.

Plan, in order, each step gated on the base:runtime histogram: (1) `$T` and `typeid` parameters bound from the argument type for scalar, pointer, slice and typeid patterns; (2) `where` clauses evaluated per instance; (3) polymorphic structs and unions `Name($T)`; (4) procedure groups over instances; (5) `$N` value parameters and specialization patterns (`$E` in `[]$E`, `$T/[]$E`).

Data: a generic definition keeps its declared signature as a pattern with the `$` names bound to slots. An instance is `(definition Entity_Id, enclosing Instance_Id, canonical arguments)`, where each argument is a type id for `$T`/`typeid`, or a typed `Const_Id` for `$N`. Arguments are ordered by declaration, defaults are filled before keying, and the key is compared in full on hash collision. Every instance gets its own typed view, so one syntax node can hold different types per instance; checked facts are never shared between instances.

Life cycle: a request reserves the instance and its concrete signature entity, marks it `Checking`, and then checks the body. A recursive request for the same key reuses the reserved instance. An invalid instance is cached as `Invalid`; a later use reports one concise note at the use site, not the original diagnostics. Errors from argument binding are reported once, at the call site, with an instantiation note naming the bound arguments. Lowering receives one function per complete instance; internal names come from the key (section 7 encoding), and enumeration sorts keys.

Budget: an explicit instantiation limit (count and nesting depth) produces its own diagnostic with the instantiation trace. This is separate from semantic invalidity.

Divergence to track: the official compiler probes deferred untyped arguments in a first pass; our first slice binds only from typed arguments and reports `Unsupported` for deferred untyped arguments until step 2.

Divergence to track (temporary): `intrinsics.has_target_feature` reads `Build_Configuration.target_features`, which is empty, so `sse2` reports false and `base:runtime` `memory_compare` takes its scalar path. The official x86-64 baseline reports `sse2` true. SIMD pending: `#simd` types, `unaligned_load`, `simd_lanes_ne`, `simd_reduce_or`, `simd_indices`, `simd_select`, `simd_reduce_min`, and V128 lowering. Enabling it later is a data change to the target feature list.

## Appendix B. Runtime builtin call batch

The initial runtime histogram had 150 `expr Unsupported Call_Expr` diagnostics. Inspecting their complete source spans found many calls to procedures whose bodies were already invalid, rather than 150 missing builtins. The first root was `max(Heap_Slab_Class)` at `base/runtime/heap_allocator_implementation.odin:732:21`. Other independent roots included `intrinsics.constant_log2`, constant and multi-argument `max`, and six calls to the unbound `type_info_of`. Maps, dynamic arrays and type switches are outside this batch.

Existing `Builtin_Plan`, exact constant operations, enum member metadata and the runtime type-info writer are reused. `core:math/big.count_bits` supplies the magnitude bit count for `constant_log2`; no integer implementation is added. Searches of `base/`, `core/`, the fork's `vendor/`, the official Odin/examples/package-documentation repositories and `/home/su3h7am/Projects/refs/Odin-upstream` found no separate reusable semantic checker. The implementation follows the simple explicit plans described in [research/01](research/01-gingerbill-vision.md), without adding syntax or language rules.

References read before implementation, under `/home/su3h7am/Projects/Odin/src`:

- `check_builtin.cpp:check_builtin_procedure`, `BuiltinProc_min`, `BuiltinProc_max`, `BuiltinProc_abs`, `BuiltinProc_clamp`, `BuiltinProc_constant_log2` and `BuiltinProc_type_info_of`. Enum extrema use actual member values, not the bounds of their backing integer. Numeric calls fold exact constants or retain runtime operands in source order. `constant_log2` returns an untyped integer, including -1 for zero and the magnitude logarithm for negative integers.
- `llvm_backend_proc.cpp:lb_build_builtin_proc`. Multi-argument min/max reduce left to right; floating abs clears the sign bit. Type operands to `type_info_of` address their descriptor; runtime typeids call `runtime.__type_info_of`.
- `big_int.cpp:big_int_log2`, which returns the magnitude bit count minus one. This builtin folds entirely in the checker and needs no runtime instruction.
- `check_expr.cpp:check_is_castable_to` and `check_range`. The enum query fixture needs an explicit enum-to-integer cast. The existing runtime `__type_info_of` loop needs `0..<n` to infer the typed upper bound rather than force `int`. Both reuse existing conversion and range lowering.

The static `type_info_of` plan names the queried type and the existing `runtime.type_table` global. Lowering loads the descriptor at its published slot. The dynamic form is an ordinary checked call to the unchanged runtime helper, so invalid IDs and collisions follow that helper's search. This retains the project's existing slot-based typeid encoding; it does not introduce another encoding or lookup implementation.

Remaining builtin families are not claimed here: float/boolean/enumerated-array type extrema, runtime string/enum min/max, complex/quaternion abs, swizzle, offset queries, additional layout variants and unsupported intrinsics still need their own bounded work. The batch does not change the existing RTTI encoding compatibility decision.

Nested named and anonymous noncapturing procedure literals reuse procedure entities, signature/body checking and symbol lowering, following `check_expr.cpp:check_expr_base` and `llvm_backend_expr.cpp:lb_build_expr`; enclosing local-variable captures are rejected and procedure control/defer/check policies are isolated.
Generic literals remain `Unsupported` with reason `Procedure_Literal_Generic`; sibling forward references still report `Undeclared_Name` because local declarations are checked in statement order, while self recursion works. Procedure-group overload resolution remains unsupported.
