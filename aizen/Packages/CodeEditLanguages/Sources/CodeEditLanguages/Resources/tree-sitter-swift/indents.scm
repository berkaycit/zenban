; Simplified indents for Swift - compatible with bundled grammar version

[
  (class_body)
  (function_declaration)
  (for_statement)
  (while_statement)
  (do_statement)
  (if_statement)
  (switch_statement)
  (guard_statement)
  (call_expression)
  (lambda_literal)
] @indent.begin

[
  "}"
  "]"
] @indent.branch @indent.end

[
  (comment)
  (multiline_comment)
] @indent.auto
