; Simplified locals for Swift - compatible with bundled grammar version

(function_declaration (simple_identifier) @definition.function)

[
  (for_statement)
  (while_statement)
  (do_statement)
  (if_statement)
  (guard_statement)
  (switch_statement)
  (function_declaration)
] @local.scope
