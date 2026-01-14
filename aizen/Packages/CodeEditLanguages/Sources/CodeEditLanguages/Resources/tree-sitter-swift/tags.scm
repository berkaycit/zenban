; Simplified tags for Swift - compatible with bundled grammar version

(function_declaration
    (simple_identifier) @name) @definition.function

(class_body
  (function_declaration
    (simple_identifier) @name)) @definition.method

(class_body
  (property_declaration
    (pattern (simple_identifier) @name))) @definition.property
