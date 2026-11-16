///|
/// A structurally plausible reading of one EOCD. Directory bytes are parsed
/// only after the candidate tier has selected exactly one reading.
priv struct DirectoryReading {
  classic : ClassicDirectoryEnd
  zip64 : UInt64?
  offset : UInt64
  size : UInt64
  entries : UInt64
  boundary : UInt64
}

///|
priv struct EndSelection {
  candidates : Array[ClassicDirectoryEnd]
  exact : Bool
  mut next : Int32
  mut chosen : DirectoryReading?
  mut earliest_error : (UInt64, ZipError)?
}

///|
/// A complete comment is required in both tiers. EOF-reaching candidates have
/// priority, even if every one fails validation; trailing data is tolerated
/// only when no candidate reaches EOF.
fn DirectoryReader::begin_selection(
  self : DirectoryReader,
  tail : Bytes,
  tail_offset : UInt64,
) -> DirectoryStep raise ZipError {
  let records = end_candidates(tail)
  let exact = records.any(record => {
    record.offset + 22 + record.comment.length() == tail.length()
  })
  let candidates = records.filter_map(record => {
    if exact && record.offset + 22 + record.comment.length() != tail.length() {
      return None
    }
    let offset = tail_offset + record.offset.to_uint64()
    let present = record.offset >= 20 &&
      tail[record.offset - 20:] is [u32le(ZIP64_LOCATOR_SIG), ..]
    Some({
      offset,
      disk: record.disk,
      central_disk: record.central_disk,
      disk_entries: record.disk_entries,
      entries: record.entries,
      central_size: record.central_size,
      central_offset: record.central_offset,
      comment: record.comment,
      probe_zip64: record.may_have_zip64(offset, present || record.offset < 20),
    })
  })
  guard !candidates.is_empty() else {
    raise ZipError(
      MissingEndOfCentral,
      "zip: end of central directory not found",
    )
  }
  let candidates = if exact { candidates } else { candidates.rev() }
  let selection = {
    candidates,
    exact,
    next: 0,
    chosen: None,
    earliest_error: None,
  }
  self.selection = Some(selection)
  self.next_candidate(selection)
}

///|
fn EndSelection::record_error(
  self : EndSelection,
  offset : UInt64,
  error : ZipError,
) -> Unit {
  if self.earliest_error is None ||
    (self.earliest_error is Some((earlier, _)) && offset < earlier) {
    self.earliest_error = Some((offset, error))
  }
}

///|
/// The ZIP64-to-classic retry has already run before this function sees an
/// asynchronous probe failure, so the saved error belongs to classic.
fn DirectoryReader::reject_candidate(
  self : DirectoryReader,
  selection : EndSelection,
  error : ZipError,
) -> DirectoryStep raise ZipError {
  selection.record_error(self.selected_end.unwrap().offset, error)
  self.next_candidate(selection)
}

///|
fn DirectoryReader::next_candidate(
  self : DirectoryReader,
  selection : EndSelection,
) -> DirectoryStep raise ZipError {
  while selection.next < selection.candidates.length() {
    let classic = selection.candidates[selection.next]
    selection.next += 1
    self.selected_end = Some(classic)
    self.selected_zip64 = None
    self.entries = []
    self.pending = b""
    try {
      guard classic.disk == 0 && classic.central_disk == 0 else {
        raise ZipError(
          UnsupportedFeature,
          "zip: multi-disk archives are not supported",
        )
      }
      if classic.probe_zip64 && classic.offset >= 20UL {
        self.phase = Locator(classic)
        return NeedRead({ offset: classic.offset - 20UL, length: 20, })
      }
      return self.begin_classic_records(classic)
    } catch {
      ZipError(kind, _) as error => {
        guard kind.directory_failure() else { raise error }
        selection.record_error(classic.offset, error)
      }
    }
  }
  self.finish_selection(selection)
}

///|
fn DirectoryReader::after_directory_probe(
  self : DirectoryReader,
  reading : DirectoryReading,
) -> DirectoryStep raise ZipError {
  guard self.selection is Some(selection) else {
    return self.begin_validated_records(reading)
  }
  if selection.chosen is Some(_) {
    raise ZipError(
      Corrupt,
      "zip: more than one end of central directory record (APPNOTE 4.3.1: MUST have only one)",
    )
  }
  selection.chosen = Some(reading)
  if selection.exact {
    self.next_candidate(selection)
  } else {
    self.finish_selection(selection)
  }
}

///|
fn DirectoryReader::finish_selection(
  self : DirectoryReader,
  selection : EndSelection,
) -> DirectoryStep raise ZipError {
  self.selection = None
  guard selection.chosen is Some(reading) else {
    let (_, error) = selection.earliest_error.unwrap()
    raise error
  }
  self.selected_end = Some(reading.classic)
  self.selected_zip64 = reading.zip64
  self.begin_validated_records(reading)
}
