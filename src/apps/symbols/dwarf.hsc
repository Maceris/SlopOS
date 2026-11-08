package symbols

import text_buffer from "std"

/*
 * DWARF 4, as Hemera's debug files have it (decisions/0185, 12e; Hemera's docs/compilation.md, Debug Info): read for
 * lines from .debug_line, and for a function's locals and where they are from .debug_info, .debug_abbrev, .debug_str
 * and .debug_loc. Everything is read from the file as it is, checked as it goes, since it came from outside: a section,
 * entry or expression that doesn't read is taken as missing, never as a reason to read past what's there. Addresses
 * are offsets in the image, as the program is linked at 0.
 */

/** An ELF section's place in the file; a size of 0 for one the file doesn't have. */
DwarfSection :: struct {
    /** Where it starts in the file. */
    at : u64,
    /** How many bytes it has. */
    size : u64,
}

/** The DWARF sections a file has. */
Dwarf :: struct {
    info : DwarfSection,
    abbrev : DwarfSection,
    strings : DwarfSection,
    line : DwarfSection,
    locations : DwarfSection,
    ranges : DwarfSection,
}

/** The most levels of entries a unit is followed into; deeper ones are skipped. */
MAX_DEPTH :: 64
/** The most entries an abbreviation table has read. */
MAX_ABBREVIATIONS :: 4096

/** Tags read. */
TAG_FORMAL_PARAMETER : u64 : 0x05
TAG_LEXICAL_BLOCK : u64 : 0x0b
TAG_COMPILE_UNIT : u64 : 0x11
TAG_INLINED_SUBROUTINE : u64 : 0x1d
TAG_SUBPROGRAM : u64 : 0x2e
TAG_VARIABLE : u64 : 0x34

/** Attributes read. */
AT_LOCATION : u64 : 0x02
AT_NAME : u64 : 0x03
AT_STMT_LIST : u64 : 0x10
AT_RANGES : u64 : 0x55
AT_LOW_PC : u64 : 0x11
AT_HIGH_PC : u64 : 0x12
AT_DECL_LINE : u64 : 0x3b
AT_ABSTRACT_ORIGIN : u64 : 0x31
AT_FRAME_BASE : u64 : 0x40
AT_SPECIFICATION : u64 : 0x47
AT_LINKAGE_NAME : u64 : 0x6e
AT_MIPS_LINKAGE_NAME : u64 : 0x2007

/** What an attribute's value is, by its form. */
DwarfValueKind :: enum {
    /** No value read, or a form not known. */
    Missing,
    /** A number: an address, a constant, a flag, or an offset into another section. */
    Number,
    /** A reference to another entry, as its offset from the file's start. */
    Reference,
    /** Text: at and size in the file. */
    Text,
    /** A block or an expression: at and size in the file. */
    Block,
}

/** An attribute's value. */
DwarfValue :: struct {
    kind : DwarfValueKind,
    /** A number's or a reference's value. */
    number : u64,
    /** Where text or a block is in the file. */
    at : u64,
    /** How many bytes it has. */
    size : u64,
    /** The form, which tells an offset into .debug_loc (sec_offset) from a constant. */
    form : u64,
}

/** A unit of .debug_info: where its entries are, and its abbreviations. */
DwarfUnit :: struct {
    /** Where its header starts, which references within it count from. */
    start : u64,
    /** Where its first entry starts. */
    entries : u64,
    /** Where it ends. */
    end : u64,
    /** Where its abbreviations start in the file. */
    abbreviations : u64,
    /** Its base address, its entry's low_pc, which .debug_loc's addresses count from. */
    base : u64,
    /** Its line program's offset in .debug_line. */
    lines : u64,
}

/** An entry read: what's needed of its attributes. */
DwarfEntry :: struct {
    /** 0 for the null entry that ends a list of children. */
    tag : u64,
    children : bool,
    name : DwarfValue,
    linkage : DwarfValue,
    low : DwarfValue,
    high : DwarfValue,
    location : DwarfValue,
    frame_base : DwarfValue,
    decl_line : DwarfValue,
    origin : DwarfValue,
    lines : DwarfValue,
    ranges : DwarfValue,
}

/**
 * Find a file's DWARF sections by their names.
 *
 * @param file An ELF64 file.
 * @return Its sections; null if it has no section names, or no .debug_info.
 */
find_dwarf :: fn(file: u8[]) -> Dwarf? {
    sections :: word(file, 0x28, 8)
    count :: word(file, 0x3c, 2)
    names_index :: word(file, 0x3e, 2)
    if word(file, 0x3a, 2) != SECTION_HEADER_SIZE || !fits(file, sections, count * SECTION_HEADER_SIZE) || names_index >= count {
        return null
    }
    names :: word(file, sections + names_index * SECTION_HEADER_SIZE + 0x18, 8)
    names_size :: word(file, sections + names_index * SECTION_HEADER_SIZE + 0x20, 8)
    if !fits(file, names, names_size) {
        return null
    }
    found := Dwarf.{}
    for i in cast[u64](0)..<count {
        header :: sections + i * SECTION_HEADER_SIZE
        name_at :: word(file, header, 4)
        if name_at >= names_size {
            continue
        }
        name :: text_at(file, names + name_at, names + names_size)
        section :: DwarfSection.{at = word(file, header + 0x18, 8), size = word(file, header + 0x20, 8)}
        if !fits(file, section.at, section.size) {
            continue
        }
        if name == ".debug_info" {
            found.info = section
        }
        else if name == ".debug_abbrev" {
            found.abbrev = section
        }
        else if name == ".debug_str" {
            found.strings = section
        }
        else if name == ".debug_line" {
            found.line = section
        }
        else if name == ".debug_loc" {
            found.locations = section
        }
        else if name == ".debug_ranges" {
            found.ranges = section
        }
    }
    if found.info.size == 0 || found.abbrev.size == 0 {
        return null
    }
    return found
}

/**
 * Read text up to its zero.
 *
 * @param file The file, which the text is a view of.
 * @param at Where it starts.
 * @param end Where what it's in ends; text reaching it is cut there.
 * @return The text; "" if it's empty or starts past the end.
 */
text_at :: fn(file: u8[], at: u64, end: u64) -> string {
    count := cast[u64](0)
    loop {
        index :: at + count
        if index >= end || index >= cast[u64](file.count) || file[cast[usize](index)] == 0 {
            break
        }
        count += 1
    }
    first :: cast[usize](at)
    if count == 0 || first >= file.count {
        return ""
    }
    return string_of(&file[first], cast[usize](count))
}

/**
 * Read an unsigned LEB128 number, moving past it.
 *
 * @param file The file.
 * @param at Where it starts, moved past its last byte.
 * @param end Where what it's in ends; a number reaching it is cut there.
 * @return Its value; bits past 64 are dropped.
 */
uleb :: fn(file: u8[], at: ptr[mut u64], end: u64) -> u64 {
    value : u64 = 0
    shift : u64 = 0
    loop {
        index :: at^
        if index >= end || index >= cast[u64](file.count) {
            return value
        }
        byte :: file[cast[usize](index)]
        at^ += 1
        if shift < 64 {
            value |= cast[u64](byte & 0x7f) << shift
        }
        shift += 7
        if byte & 0x80 == 0 {
            return value
        }
    }
}

/**
 * Read a signed LEB128 number, moving past it.
 *
 * @param file The file.
 * @param at Where it starts, moved past its last byte.
 * @param end Where what it's in ends.
 * @return Its value.
 */
sleb :: fn(file: u8[], at: ptr[mut u64], end: u64) -> i64 {
    value : u64 = 0
    shift : u64 = 0
    loop {
        index :: at^
        if index >= end || index >= cast[u64](file.count) {
            return cast[i64](value)
        }
        byte :: file[cast[usize](index)]
        at^ += 1
        if shift < 64 {
            value |= cast[u64](byte & 0x7f) << shift
        }
        shift += 7
        if byte & 0x80 == 0 {
            if shift < 64 && byte & 0x40 != 0 {
                value |= ~cast[u64](0) << shift
            }
            return cast[i64](value)
        }
    }
}

/**
 * Take a fixed-size number, moving past it.
 *
 * @param file The file.
 * @param at Where it starts, moved past it.
 * @param count How many bytes, 1 to 8.
 * @return Its value.
 */
take :: fn(file: u8[], at: ptr[mut u64], count: u64) -> u64 {
    value :: word(file, at^, count)
    at^ += count
    return value
}

/**
 * Read a unit's header.
 *
 * @param file The file.
 * @param dwarf Its sections.
 * @param at Where the header starts, in .debug_info.
 * @return The unit; null if it isn't a 32-bit DWARF 2 to 4 unit with 8-byte addresses that fits.
 */
unit_at :: fn(file: u8[], dwarf: Dwarf, at: u64) -> DwarfUnit? {
    info_end :: dwarf.info.at + dwarf.info.size
    length :: word(file, at, 4)
    if length >= 0xfffffff0 || at + 4 + length > info_end {
        return null
    }
    version :: word(file, at + 4, 2)
    if version < 2 || version > 4 || word(file, at + 10, 1) != 8 {
        return null
    }
    abbreviations :: word(file, at + 6, 4)
    if abbreviations >= dwarf.abbrev.size {
        return null
    }
    made := DwarfUnit.{start = at, entries = at + 11, end = at + 4 + length, abbreviations = dwarf.abbrev.at + abbreviations}
    // Its own entry, for its base address and line program
    cursor := made.entries
    match entry_at(file, dwarf, made, &cursor) {
        case Some(first) => {
            made.base = if first.low.kind == .Number { first.low.number } else { 0 }
            made.lines = if first.lines.kind == .Number { first.lines.number } else { ~cast[u64](0) }
        }
        case None => return null
    }
    return made
}

/**
 * Find an abbreviation by its code.
 *
 * @param file The file.
 * @param dwarf Its sections.
 * @param unit The unit, whose abbreviations are searched.
 * @param code The code, not 0.
 * @return Where its tag starts; null if the table hasn't the code.
 */
abbreviation :: fn(file: u8[], dwarf: Dwarf, unit: DwarfUnit, code: u64) -> u64? {
    end :: dwarf.abbrev.at + dwarf.abbrev.size
    at := unit.abbreviations
    for i in 0..<MAX_ABBREVIATIONS {
        found :: uleb(file, &at, end)
        if found == 0 || at >= end {
            return null
        }
        if found == code {
            return at
        }
        _ = uleb(file, &at, end)
        at += 1
        // Its attributes, to the pair of zeros
        loop {
            name :: uleb(file, &at, end)
            form :: uleb(file, &at, end)
            if (name == 0 && form == 0) || at >= end {
                break
            }
        }
    }
    return null
}

/**
 * Read an attribute's value by its form, moving past it.
 *
 * @param file The file.
 * @param dwarf Its sections.
 * @param unit The entry's unit, which references count from.
 * @param form The form.
 * @param at Where the value starts, moved past it.
 * @return The value; Missing for a form not known, after which nothing more of the entry can be read.
 */
value_of :: fn(file: u8[], dwarf: Dwarf, unit: DwarfUnit, form: u64, at: ptr[mut u64]) -> DwarfValue {
    end :: unit.end
    made := DwarfValue.{kind = .Number, form = form}
    if form == 0x01 || form == 0x07 || form == 0x14 || form == 0x20 {
        made.number = take(file, at, 8)
    }
    else if form == 0x05 || form == 0x12 {
        made.number = take(file, at, 2)
    }
    else if form == 0x06 || form == 0x13 || form == 0x10 || form == 0x17 {
        made.number = take(file, at, 4)
    }
    else if form == 0x0b || form == 0x0c || form == 0x11 {
        made.number = take(file, at, 1)
    }
    else if form == 0x0d {
        made.number = cast[u64](sleb(file, at, end))
    }
    else if form == 0x0f || form == 0x15 {
        made.number = uleb(file, at, end)
    }
    else if form == 0x19 {
        made.number = 1
    }
    else if form == 0x08 {
        made.kind = .Text
        made.at = at^
        made.size = cast[u64](text_at(file, at^, end).count)
        at^ += made.size + 1
    }
    else if form == 0x0e {
        offset :: take(file, at, 4)
        made.kind = .Text
        if offset < dwarf.strings.size {
            made.at = dwarf.strings.at + offset
            made.size = cast[u64](text_at(file, made.at, dwarf.strings.at + dwarf.strings.size).count)
        }
    }
    else if form == 0x09 || form == 0x18 || form == 0x0a || form == 0x03 || form == 0x04 {
        size :: if form == 0x0a { take(file, at, 1) } else if form == 0x03 { take(file, at, 2) } else if form == 0x04 { take(file, at, 4) } else { uleb(file, at, end) }
        made.kind = .Block
        made.at = at^
        made.size = size
        at^ += size
    }
    else if form == 0x16 {
        return value_of(file, dwarf, unit, uleb(file, at, end), at)
    }
    else {
        made.kind = .Missing
    }
    // A reference within the unit, as an offset from the file's start
    if form >= 0x11 && form <= 0x15 {
        made.kind = .Reference
        made.number += unit.start
    }
    else if form == 0x10 {
        made.kind = .Reference
        made.number += dwarf.info.at
    }
    return made
}

/**
 * Read an entry, moving past it.
 *
 * @param file The file.
 * @param dwarf Its sections.
 * @param unit Its unit.
 * @param at Where it starts, moved past it.
 * @return The entry, tag 0 for a null one; null if its abbreviation isn't there, it has a form not known, or it runs
 *     past its unit.
 */
entry_at :: fn(file: u8[], dwarf: Dwarf, unit: DwarfUnit, at: ptr[mut u64]) -> DwarfEntry? {
    if at^ >= unit.end {
        return null
    }
    code :: uleb(file, at, unit.end)
    made := DwarfEntry.{}
    if code == 0 {
        return made
    }
    abbrev_end :: dwarf.abbrev.at + dwarf.abbrev.size
    specs := abbreviation(file, dwarf, unit, code) or_return null
    made.tag = uleb(file, &specs, abbrev_end)
    made.children = word(file, specs, 1) != 0
    specs += 1
    loop {
        name :: uleb(file, &specs, abbrev_end)
        form :: uleb(file, &specs, abbrev_end)
        if (name == 0 && form == 0) || specs >= abbrev_end {
            break
        }
        value :: value_of(file, dwarf, unit, form, at)
        if value.kind == .Missing || at^ > unit.end {
            return null
        }
        if name == AT_NAME {
            made.name = value
        }
        else if name == AT_LINKAGE_NAME || name == AT_MIPS_LINKAGE_NAME {
            made.linkage = value
        }
        else if name == AT_LOW_PC {
            made.low = value
        }
        else if name == AT_HIGH_PC {
            made.high = value
        }
        else if name == AT_LOCATION {
            made.location = value
        }
        else if name == AT_FRAME_BASE {
            made.frame_base = value
        }
        else if name == AT_DECL_LINE {
            made.decl_line = value
        }
        else if (name == AT_ABSTRACT_ORIGIN || name == AT_SPECIFICATION) && value.kind == .Reference {
            made.origin = value
        }
        else if name == AT_STMT_LIST {
            made.lines = value
        }
        else if name == AT_RANGES {
            made.ranges = value
        }
    }
    return made
}

/**
 * Fill in what an entry has from the entry it's an instance of (abstract_origin or specification): its name, its
 * linkage name and its line, where it hasn't its own, through a few levels.
 *
 * @param file The file.
 * @param dwarf Its sections.
 * @param unit Its unit, where the other entry is.
 * @param entry The entry, filled in.
 */
complete :: fn(file: u8[], dwarf: Dwarf, unit: DwarfUnit, entry: ptr[mut DwarfEntry]) {
    origin := entry.origin
    for i in 0..<4 {
        if origin.kind != .Reference || (entry.name.kind == .Text && entry.linkage.kind == .Text && entry.decl_line.kind == .Number) {
            return void
        }
        at := origin.number
        other :: entry_at(file, dwarf, unit, &at) or_return void
        if entry.name.kind != .Text {
            entry.name = other.name
        }
        if entry.linkage.kind != .Text {
            entry.linkage = other.linkage
        }
        if entry.decl_line.kind != .Number {
            entry.decl_line = other.decl_line
        }
        origin = other.origin
    }
}

/**
 * The text a Text value is.
 *
 * @param file The file, which it's a view of.
 * @param value The value.
 * @return Its text; "" for any other kind.
 */
text_of_value :: fn(file: u8[], value: DwarfValue) -> string {
    if value.kind != .Text {
        return ""
    }
    return text_at(file, value.at, value.at + value.size)
}

/**
 * Whether an entry's code covers an address, by its low_pc and high_pc, or its ranges in .debug_ranges.
 *
 * @param file The file.
 * @param dwarf Its sections.
 * @param unit The entry's unit, whose base address ranges count from.
 * @param entry The entry.
 * @param address The address.
 * @return True when one of its ranges holds the address; false without any.
 */
covers :: fn(file: u8[], dwarf: Dwarf, unit: DwarfUnit, entry: DwarfEntry, address: u64) -> bool {
    if entry.ranges.kind == .Number && entry.ranges.number < dwarf.ranges.size {
        end :: dwarf.ranges.at + dwarf.ranges.size
        at := dwarf.ranges.at + entry.ranges.number
        base := unit.base
        loop {
            if at + 16 > end {
                return false
            }
            first :: take(file, &at, 8)
            last :: take(file, &at, 8)
            if first == 0 && last == 0 {
                return false
            }
            if first == ~cast[u64](0) {
                base = last
            }
            else if address >= base + first && address < base + last {
                return true
            }
        }
    }
    if entry.low.kind != .Number || entry.high.kind != .Number {
        return false
    }
    low :: entry.low.number
    // high_pc is an address with the addr form, and otherwise how far past low_pc
    high :: if entry.high.form == 0x01 { entry.high.number } else { low + entry.high.number }
    return address >= low && address < high
}

/**
 * Describe a function's locals at an address, for the debugger: "function <linkage name>", "frame <register>" when
 * its frame base is a register, then "local <name> <line> <where>" for each parameter and variable in scope there,
 * then "end", each line ending in a newline; "?" if no function holds it. <where> is a word, as say_expression says
 * it. Registers are DWARF's numbers.
 *
 * @param file The file.
 * @param dwarf Its sections.
 * @param address The address, an offset in the image: a program counter, or a return address less one.
 * @param into Where the lines go.
 */
describe_locals :: fn(file: u8[], dwarf: Dwarf, address: u64, into: ptr[mut text_buffer.TextBuffer]) {
    info_end :: dwarf.info.at + dwarf.info.size
    start := dwarf.info.at
    loop {
        if start >= info_end {
            break
        }
        match unit_at(file, dwarf, start) {
            case Some(unit) => {
                start = unit.end
                if locals_in_unit(file, dwarf, unit, address, into) {
                    return void
                }
            }
            case None => break
        }
    }
    text_buffer.append(into, "?\n")
}

/**
 * describe_locals in one unit. The locals said are the innermost function's whose code holds the address: an inlined
 * call's, when the address is in one, with its linkage name, and otherwise the function's.
 *
 * @return True once the function holding the address was found and described; false if this unit hasn't it.
 */
locals_in_unit :: fn(file: u8[], dwarf: Dwarf, unit: DwarfUnit, address: u64, into: ptr[mut text_buffer.TextBuffer]) -> bool {
    at := unit.entries
    // Whether each level holds the address: the function's, the lexical blocks' and the inlined calls' within it
    in_scope : bool[MAX_DEPTH]
    // Which function's or inlined call's each level's children are, by its depth
    owners : usize[MAX_DEPTH]
    depth : usize = 0
    function_depth : usize = MAX_DEPTH
    // The innermost function or inlined call holding the address, by its depth, and its locals
    owner : usize = MAX_DEPTH
    storage : u8[REPLY_BYTES]
    locals := text_buffer.make(storage)
    name_storage : u8[512]
    function_name := text_buffer.make(name_storage)
    frame_storage : u8[64]
    frame := text_buffer.make(frame_storage)
    loop {
        if at >= unit.end {
            break
        }
        found :: entry_at(file, dwarf, unit, &at) or_return false
        if found.tag == 0 {
            if depth == 0 {
                break
            }
            depth -= 1
            if depth <= function_depth && function_depth < MAX_DEPTH {
                // The function's children are all read
                break
            }
            continue
        }
        entry := found
        outer :: if depth > 0 && depth - 1 < in_scope.count { in_scope[depth - 1] } else { true }
        parent_owner :: if depth > 0 && depth - 1 < owners.count { owners[depth - 1] } else { MAX_DEPTH }
        holds := false
        this_owner := parent_owner
        if entry.tag == TAG_SUBPROGRAM && function_depth == MAX_DEPTH && covers(file, dwarf, unit, entry, address) {
            complete(file, dwarf, unit, &entry)
            function_name = text_buffer.make(name_storage)
            text_buffer.append(&function_name, text_of_value(file, entry.linkage))
            say_frame_base(file, entry, &frame)
            function_depth = depth
            owner = depth
            this_owner = depth
            holds = true
            if !entry.children {
                break
            }
        }
        else if function_depth < MAX_DEPTH && outer && entry.tag == TAG_INLINED_SUBROUTINE && covers(file, dwarf, unit, entry, address) {
            // An inlined call holding the address: its locals, not the function's
            complete(file, dwarf, unit, &entry)
            function_name = text_buffer.make(name_storage)
            text_buffer.append(&function_name, text_of_value(file, entry.linkage))
            locals = text_buffer.make(storage)
            owner = depth
            this_owner = depth
            holds = true
        }
        else if function_depth < MAX_DEPTH && outer && entry.tag == TAG_LEXICAL_BLOCK {
            holds = covers(file, dwarf, unit, entry, address) || (entry.low.kind != .Number && entry.ranges.kind != .Number)
        }
        else if function_depth < MAX_DEPTH && outer && parent_owner == owner
            && (entry.tag == TAG_VARIABLE || entry.tag == TAG_FORMAL_PARAMETER) {
            complete(file, dwarf, unit, &entry)
            name :: text_of_value(file, entry.name)
            if name != "" {
                line :: if entry.decl_line.kind == .Number { entry.decl_line.number } else { 0 }
                text_buffer.append_format(&locals, "local % % ", name, line)
                say_location(file, dwarf, unit, entry.location, address, &locals)
                text_buffer.append(&locals, "\n")
            }
        }
        if entry.children {
            if depth < in_scope.count {
                in_scope[depth] = holds
            }
            if depth < owners.count {
                owners[depth] = this_owner
            }
            depth += 1
        }
    }
    if function_depth == MAX_DEPTH {
        return false
    }
    text_buffer.append_format(into, "function %\n", text_buffer.as_string(&function_name))
    text_buffer.append(into, text_buffer.as_string(&frame))
    text_buffer.append(into, text_buffer.as_string(&locals))
    text_buffer.append(into, "end\n")
    return true
}

/**
 * Say a function's frame base, when it's a register: "frame <register>\n".
 *
 * @param file The file.
 * @param entry The function's entry.
 * @param into Where the line goes; nothing for a frame base that isn't one register.
 */
say_frame_base :: fn(file: u8[], entry: DwarfEntry, into: ptr[mut text_buffer.TextBuffer]) {
    base :: entry.frame_base
    if base.kind != .Block || base.size == 0 {
        return void
    }
    op :: word(file, base.at, 1)
    if op >= 0x50 && op <= 0x6f && base.size == 1 {
        text_buffer.append_format(into, "frame %\n", op - 0x50)
    }
    else if op == 0x90 {
        at := base.at + 1
        text_buffer.append_format(into, "frame %\n", uleb(file, &at, base.at + base.size))
    }
}

/**
 * Say where a local is at an address: from its expression, or from its location list's entry for the address.
 *
 * @param file The file.
 * @param dwarf Its sections.
 * @param unit Its unit, whose base address the list counts from.
 * @param location Its location attribute.
 * @param address The address.
 * @param into Where it's said.
 */
say_location :: fn(file: u8[], dwarf: Dwarf, unit: DwarfUnit, location: DwarfValue, address: u64, into: ptr[mut text_buffer.TextBuffer]) {
    if location.kind == .Block {
        say_expression(file, location.at, location.size, into)
        return void
    }
    if location.kind != .Number || location.number >= dwarf.locations.size {
        text_buffer.append(into, "n")
        return void
    }
    end :: dwarf.locations.at + dwarf.locations.size
    at := dwarf.locations.at + location.number
    base := unit.base
    loop {
        if at + 16 > end {
            break
        }
        first :: take(file, &at, 8)
        last :: take(file, &at, 8)
        if first == 0 && last == 0 {
            break
        }
        if first == ~cast[u64](0) {
            base = last
            continue
        }
        size :: take(file, &at, 2)
        if address >= base + first && address < base + last {
            say_expression(file, at, size, into)
            return void
        }
        at += size
    }
    text_buffer.append(into, "n")
}

/**
 * Say where a DWARF expression puts a value, as one word: "m:<register>:<offset>" in memory at a register's value plus
 * an offset ("m:f:<offset>" from the function's frame base), "r:<register>" in a register, "a:<address>" at an address
 * in the image, "c:<value>" a constant, or "n" where it isn't kept, or is kept in a way not read here. A value in pieces
 * is "p:" and its pieces, "<bytes>=<where>" each, joined by commas, like "p:8=m:f:-88,8=n". Registers are DWARF's
 * numbers, and numbers are in decimal.
 *
 * @param file The file.
 * @param at Where the expression starts.
 * @param size How many bytes it has.
 * @param into Where it's said.
 */
say_expression :: fn(file: u8[], at: u64, size: u64, into: ptr[mut text_buffer.TextBuffer]) {
    end :: at + size
    if size == 0 || !fits(file, at, size) {
        text_buffer.append(into, "n")
        return void
    }
    // Each piece's place, said after its size once the piece ends it; a whole value is one place and no piece
    storage : u8[256]
    pieces := text_buffer.make(storage)
    place_storage : u8[64]
    place := text_buffer.make(place_storage)
    has_place := false
    piece_count : u64 = 0
    cursor := at
    loop {
        if cursor >= end {
            break
        }
        op :: take(file, &cursor, 1)
        if op == 0x93 {
            // A piece of so many bytes, where the place before it says, or nowhere
            bytes :: uleb(file, &cursor, end)
            if piece_count > 0 {
                text_buffer.append(&pieces, ",")
            }
            text_buffer.append_format(&pieces, "%=%", bytes, if has_place { text_buffer.as_string(&place) } else { "n" })
            piece_count += 1
            place = text_buffer.make(place_storage)
            has_place = false
            continue
        }
        if has_place && op != 0x9f {
            // Two places with no piece between them: a value worked out, which isn't read here
            text_buffer.append(into, "n")
            return void
        }
        if op == 0x91 {
            text_buffer.append_format(&place, "m:f:%", sleb(file, &cursor, end))
        }
        else if op >= 0x70 && op <= 0x8f {
            text_buffer.append_format(&place, "m:%:%", op - 0x70, sleb(file, &cursor, end))
        }
        else if op == 0x92 {
            register :: uleb(file, &cursor, end)
            text_buffer.append_format(&place, "m:%:%", register, sleb(file, &cursor, end))
        }
        else if op >= 0x50 && op <= 0x6f {
            text_buffer.append_format(&place, "r:%", op - 0x50)
        }
        else if op == 0x90 {
            text_buffer.append_format(&place, "r:%", uleb(file, &cursor, end))
        }
        else if op == 0x03 {
            text_buffer.append_format(&place, "a:%", take(file, &cursor, 8))
        }
        else if op >= 0x30 && op <= 0x4f {
            text_buffer.append_format(&place, "c:%", op - 0x30)
        }
        else if op == 0x10 {
            text_buffer.append_format(&place, "c:%", uleb(file, &cursor, end))
        }
        else if op == 0x11 {
            text_buffer.append_format(&place, "c:%", cast[u64](sleb(file, &cursor, end)))
        }
        else if op >= 0x08 && op <= 0x0f {
            // const1u to const8s: 1, 2, 4 or 8 bytes
            bytes : u64 = if op <= 0x09 { 1 } else if op <= 0x0b { 2 } else if op <= 0x0d { 4 } else { 8 }
            text_buffer.append_format(&place, "c:%", take(file, &cursor, bytes))
        }
        else if op == 0x9f {
            // stack_value: the constant before it is the value itself, as it's said already
            if !has_place {
                text_buffer.append(into, "n")
                return void
            }
            continue
        }
        else {
            text_buffer.append(into, "n")
            return void
        }
        has_place = true
    }
    if piece_count == 0 {
        text_buffer.append(into, if has_place { text_buffer.as_string(&place) } else { "n" })
        return void
    }
    text_buffer.append_format(into, "p:%", text_buffer.as_string(&pieces))
}

/** One row of a line program's table. */
LineRow :: struct {
    address : u64,
    /** Its file's index, from 1. */
    file_index : u64,
    line : u64,
    is_statement : bool,
    /** Whether it ends a sequence: its address is the first past it. */
    ends : bool,
}

/** A line program being run, row by row. */
LineProgram :: struct {
    /** Where its header starts, and where its opcodes start and end. */
    header : u64,
    at : u64,
    end : u64,
    /** Where its file names start. */
    files : u64,
    minimum_length : u64,
    default_statement : bool,
    line_base : i64,
    line_range : u64,
    opcode_base : u64,
    /** Where the standard opcodes' lengths are. */
    lengths : u64,
    /** The state machine. */
    row : LineRow,
}

/**
 * Start a line program.
 *
 * @param file The file.
 * @param dwarf Its sections.
 * @param offset The program's offset in .debug_line.
 * @return The program, at its first opcode; null if its header doesn't read, or it isn't version 2 to 4.
 */
line_program :: fn(file: u8[], dwarf: Dwarf, offset: u64) -> LineProgram? {
    if offset >= dwarf.line.size {
        return null
    }
    start :: dwarf.line.at + offset
    length :: word(file, start, 4)
    end :: start + 4 + length
    version :: word(file, start + 4, 2)
    if length >= 0xfffffff0 || end > dwarf.line.at + dwarf.line.size || version < 2 || version > 4 {
        return null
    }
    header_length :: word(file, start + 6, 4)
    at := start + 10
    made := LineProgram.{header = start, at = start + 10 + header_length, end = end}
    made.minimum_length = take(file, &at, 1)
    if version >= 4 {
        at += 1
    }
    made.default_statement = take(file, &at, 1) != 0
    made.line_base = cast[i64](cast[i8](cast[u8](take(file, &at, 1))))
    made.line_range = take(file, &at, 1)
    made.opcode_base = take(file, &at, 1)
    if made.line_range == 0 || made.opcode_base == 0 {
        return null
    }
    made.lengths = at
    at += made.opcode_base - 1
    // The include directories, to an empty one
    loop {
        if at >= end {
            return null
        }
        name :: text_at(file, at, end)
        at += cast[u64](name.count) + 1
        if name.count == 0 {
            break
        }
    }
    made.files = at
    reset_row(&made)
    return made
}

/**
 * Set a line program's state machine as each sequence starts.
 *
 * @param program The program.
 */
reset_row :: fn(program: ptr[mut LineProgram]) {
    program.row = LineRow.{file_index = 1, line = 1, is_statement = program.default_statement}
}

/**
 * Run a line program to its next row.
 *
 * @param file The file.
 * @param program The program, moved on.
 * @return The row; null at the program's end, or where it stops reading.
 */
next_row :: fn(file: u8[], program: ptr[mut LineProgram]) -> LineRow? {
    // A row that ended a sequence was given; the next starts afresh
    if program.row.ends {
        reset_row(program)
    }
    end :: program.end
    loop {
        if program.at >= end {
            return null
        }
        opcode :: take(file, &program.at, 1)
        if opcode >= program.opcode_base {
            adjusted :: opcode - program.opcode_base
            program.row.address += (adjusted / program.line_range) * program.minimum_length
            program.row.line = cast[u64](cast[i64](program.row.line) + program.line_base + cast[i64](adjusted % program.line_range))
            return program.row
        }
        if opcode == 0 {
            size :: uleb(file, &program.at, end)
            after :: program.at + size
            extended :: take(file, &program.at, 1)
            if extended == 1 {
                program.row.ends = true
                program.at = after
                return program.row
            }
            if extended == 2 {
                program.row.address = word(file, program.at, 8)
            }
            program.at = after
        }
        else if opcode == 1 {
            return program.row
        }
        else if opcode == 2 {
            program.row.address += uleb(file, &program.at, end) * program.minimum_length
        }
        else if opcode == 3 {
            program.row.line = cast[u64](cast[i64](program.row.line) + sleb(file, &program.at, end))
        }
        else if opcode == 4 {
            program.row.file_index = uleb(file, &program.at, end)
        }
        else if opcode == 5 {
            _ = uleb(file, &program.at, end)
        }
        else if opcode == 6 {
            program.row.is_statement = !program.row.is_statement
        }
        else if opcode == 8 {
            program.row.address += ((255 - program.opcode_base) / program.line_range) * program.minimum_length
        }
        else if opcode == 9 {
            program.row.address += take(file, &program.at, 2)
        }
        else if opcode == 7 || opcode == 10 || opcode == 11 {}
        else {
            // One not known: skipped by its operands' count
            count :: word(file, program.lengths + opcode - 1, 1)
            for i in cast[u64](0)..<count {
                _ = uleb(file, &program.at, end)
            }
        }
    }
}

/**
 * A line program's file's name, by its index.
 *
 * @param file The file.
 * @param program The program.
 * @param index The index, from 1.
 * @return Its name, as the program has it; "?" if there's no such file.
 */
file_name :: fn(file: u8[], program: LineProgram, index: u64) -> string {
    at := program.files
    for i in cast[u64](1)..<(index + 1) {
        if at >= program.end {
            return "?"
        }
        name :: text_at(file, at, program.end)
        if name.count == 0 {
            return "?"
        }
        if i == index {
            return name
        }
        at += cast[u64](name.count) + 1
        _ = uleb(file, &at, program.end)
        _ = uleb(file, &at, program.end)
        _ = uleb(file, &at, program.end)
    }
    return "?"
}

/**
 * Say the file and line an address is on: "file:line\n", or "?\n".
 *
 * @param file The file.
 * @param dwarf Its sections.
 * @param address The address: a program counter, or a return address less one.
 * @param into Where it's said.
 */
describe_line :: fn(file: u8[], dwarf: Dwarf, address: u64, into: ptr[mut text_buffer.TextBuffer]) {
    offset := cast[u64](0)
    loop {
        if offset >= dwarf.line.size {
            break
        }
        program := LineProgram.{}
        match line_program(file, dwarf, offset) {
            case Some(found) => program = found
            case None => break
        }
        offset = program.end - dwarf.line.at
        previous : LineRow? = null
        loop {
            row := LineRow.{}
            match next_row(file, &program) {
                case Some(found) => row = found
                case None => break
            }
            match previous {
                case Some(before) => {
                    if !before.ends && address >= before.address && address < row.address {
                        // Line 0 is code no line is for, like a trap the compiler shares between several
                        if before.line == 0 {
                            text_buffer.append(into, "?\n")
                        }
                        else {
                            text_buffer.append_format(into, "%:%\n", file_name(file, program, before.file_index), before.line)
                        }
                        return void
                    }
                }
                case None => {}
            }
            previous = row
        }
    }
    text_buffer.append(into, "?\n")
}

/**
 * Say the lowest address of a file's line: "0x1c40\n", or "?\n" when no statement is on it.
 *
 * @param file The file.
 * @param dwarf Its sections.
 * @param wanted The file's name, or the end of it after a /, like "main.hsc" for "src/main.hsc".
 * @param line The line.
 * @param into Where it's said.
 */
describe_address :: fn(file: u8[], dwarf: Dwarf, wanted: string, line: u64, into: ptr[mut text_buffer.TextBuffer]) {
    best : u64? = null
    offset := cast[u64](0)
    loop {
        if offset >= dwarf.line.size {
            break
        }
        program := LineProgram.{}
        match line_program(file, dwarf, offset) {
            case Some(found) => program = found
            case None => break
        }
        offset = program.end - dwarf.line.at
        loop {
            row := LineRow.{}
            match next_row(file, &program) {
                case Some(found) => row = found
                case None => break
            }
            if row.ends || !row.is_statement || row.line != line {
                continue
            }
            if !names_file(file_name(file, program, row.file_index), wanted) {
                continue
            }
            if (best or_else ~cast[u64](0)) > row.address {
                best = row.address
            }
        }
    }
    match best {
        case Some(address) => text_buffer.append_format(into, "%{#x}\n", address)
        case None => text_buffer.append(into, "?\n")
    }
}

/**
 * Whether a file's name is the one wanted: the same, or ending in it after a /.
 *
 * @param name The name, as a line program has it.
 * @param wanted The name wanted.
 * @return True if they match.
 */
names_file :: fn(name: string, wanted: string) -> bool {
    if wanted.count == 0 || wanted.count > name.count {
        return false
    }
    bytes :: string_bytes(name)
    from :: name.count - wanted.count
    if from >= bytes.count || string_of(&bytes[from], wanted.count) != wanted {
        return false
    }
    return from == 0 || (from - 1 < bytes.count && bytes[from - 1] == 0x2f)
}
