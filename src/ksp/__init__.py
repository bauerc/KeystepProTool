"""KeyStep Pro project format: parsing, modelling and MIDI conversion.

This package is the pure format-and-model layer. It must not import from
``ksp_cli``, print, read ``sys.argv``, or make policy decisions about where
files live -- callers hand it data and it hands data back.

That purity is deliberate. It keeps the same logic usable behind a CLI, a
frozen binary or a native GUI shell, and it keeps a future Swift port a
translation of pure functions rather than a redesign. See ROADMAP.md.
"""

__version__ = "0.1.0"
