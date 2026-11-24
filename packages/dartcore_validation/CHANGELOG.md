## 0.1.0

- `Validate.request` with Laravel-style rule strings (`required|string|min:3`) and rule lists.
- Nested fields (dot notation) and array wildcards (`items.*.qty`).
- Conditional rules (`required_if`, `required_with`, `required_unless`), `confirmed`, `same`, `in`, `regex`, `bail` and more.
- Custom rules via `Rule.custom` and `Rule.customAsync`; message and attribute overrides.
- Async `unique` and `exists` rules through `Validate.requestAsync`.
- `validated` returns only fields that had rules; unknown rules throw instead of passing silently.

First release.
