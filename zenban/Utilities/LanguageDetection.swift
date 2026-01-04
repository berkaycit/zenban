import Foundation
import CodeEditLanguages

struct LanguageDetection {
    static func codeLanguage(for path: String) -> CodeLanguage {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return CodeLanguage.default }
        return codeLanguageFromString(ext)
    }

    static func codeLanguageFromString(_ lang: String) -> CodeLanguage {
        switch lang.lowercased() {
        case "swift": return .swift
        case "js", "javascript": return .javascript
        case "jsx": return .jsx
        case "ts", "typescript": return .typescript
        case "tsx": return .tsx
        case "py", "python": return .python
        case "rb", "ruby": return .ruby
        case "java": return .java
        case "kt", "kotlin": return .kotlin
        case "c": return .c
        case "cpp", "cxx", "cc", "c++": return .cpp
        case "h", "hpp", "hxx": return .c
        case "cs", "csharp": return .cSharp
        case "go": return .go
        case "mod", "gomod": return .goMod
        case "rs", "rust": return .rust
        case "php": return .php
        case "html", "htm": return .html
        case "css", "scss", "sass", "less": return .css
        case "json": return .json
        case "md", "markdown": return .markdown
        case "sh", "bash", "zsh": return .bash
        case "sql": return .sql
        case "yaml", "yml": return .yaml
        case "dockerfile": return .dockerfile
        case "lua": return .lua
        case "perl", "pl": return .perl
        case "elixir", "ex", "exs": return .elixir
        case "haskell", "hs": return .haskell
        case "scala": return .scala
        case "dart": return .dart
        case "julia", "jl": return .julia
        case "toml": return .toml
        case "zig": return .zig
        case "verilog": return .verilog
        case "objc", "m", "mm", "objective-c": return .objc
        case "ocaml", "ml": return .ocaml
        case "regex": return .regex
        case "jsdoc": return .jsdoc
        case "agda": return .agda
        default: return CodeLanguage.default
        }
    }
}
