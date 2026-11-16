// Derived from moonbitlang/core archive/zip/extends.mbt at 25a579771; modified.
// Copyright 2026 International Digital Economy Academy
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
/// Compare resource kinds through dot syntax.
pub extend LimitKind with Eq::{equal}

///|
/// Compare ZIP failure categories through dot syntax.
pub extend ZipErrorKind with Eq::{equal}

///|
/// Compare compression methods through dot syntax.
pub extend Compression with Eq::{equal}

///|
/// Compatibility inequality method; prefer the operator.
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend LimitKind with Eq::{not_equal}

///|
/// Compatibility debug method; prefer the trait.
#deprecated("Use `Debug::to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend LimitKind with @debug.Debug::{to_repr}

///|
/// Compatibility inequality method; prefer the operator.
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend ZipErrorKind with Eq::{not_equal}

///|
/// Compatibility debug method; prefer the trait.
#deprecated("Use `Debug::to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend ZipErrorKind with @debug.Debug::{to_repr}

///|
/// Compatibility inequality method; prefer the operator.
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend Compression with Eq::{not_equal}

///|
/// Compatibility debug method; prefer the trait.
#deprecated("Use `Debug::to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend Compression with @debug.Debug::{to_repr}

///|
/// Compatibility debug method; prefer the trait.
#deprecated("Use `Debug::to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend ZipError with @debug.Debug::{to_repr}

///|
/// Format a ZIP error with its machine-readable category and diagnostic.
pub extend ZipError with Show::{to_string}

///|
/// Compatibility logging method; prefer the trait or interpolation.
#deprecated("Use `Show::output` via the trait or string interpolation instead", skip_current_package=true)
#doc(hidden)
pub extend ZipError with Show::{output}
