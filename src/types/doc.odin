package types

// Package types stores immutable semantic type descriptors under deterministic
// Type_Id handles and computes size, alignment, field offsets, and union tags.
// Layout_Config selects target widths and alignment limits; DEFAULT_LAYOUT is
// Linux x86-64. ABI classification is intentionally implemented separately.
