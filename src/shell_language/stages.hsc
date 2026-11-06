package shell_language

import runtime from "base"

/*
 * The built-in stages' work that evaluates nothing: sorting and grouping a pipeline's items by a field.
 */

/**
 * Find what an item is sorted or grouped by: a field of it, or itself.
 *
 * @param item The item, of any kind; what's given back shares any list or record in it.
 * @param name The field's name; "" for the item itself.
 * @return The field's value, or the item; Null for an item that isn't a record, or hasn't the field.
 */
key_of :: fn(item: Value, name: string) -> Value {
    if name.count == 0 {
        return item
    }
    match item {
        case Record(record) => return field(record, name) or_else Value.Null
        case _ => return .Null
    }
}

/**
 * Sort items in order by a field, or by themselves, as sort does: those that don't compare stay in the order they
 * came, and so do equal ones.
 *
 * @param items The items, which aren't changed; the list made shares any list or record in them.
 * @param field The field's name; "" to sort the items by themselves.
 * @param descending Whether the largest come first.
 * @return A new list of them, sorted, on the heap, never freed.
 */
sort_items :: fn(items #escaping : Value[], field: string, descending: bool) -> ptr[mut ValueList] {
    made :: new_list()
    for item in items {
        // Insertion: after every item it doesn't come before
        position := made.items.count
        for placed, i in made.items {
            order :: compare(key_of(item, field), key_of(placed, field)) or_else 0
            if (if descending { order > 0 } else { order < 0 }) {
                position = i
                break
            }
        }
        // The list again, with it in its place
        next : Value[..]
        for placed, i in made.items {
            if i == position {
                runtime.array_add(&next, item)
            }
            runtime.array_add(&next, placed)
        }
        if position >= made.items.count {
            runtime.array_add(&next, item)
        }
        runtime.array_free(&made.items)
        made.items = next
    }
    return made
}

/**
 * Group items by a field, as group does: a record for each of the field's values, in the order they first come, of
 * the value (named as the field), count, how many, and items, the items with it.
 *
 * Grouped by a field named count or items, the value is named key instead, so the group's own fields don't take its
 * place.
 *
 * @param items The items, which aren't changed; the groups share any list or record in them.
 * @param name The field's name, not empty; an item that isn't a record, or hasn't the field, is grouped under null.
 * @return A new list of the groups, on the heap, never freed; empty for no items.
 */
group_items :: fn(items #escaping : Value[], name #escaping : string) -> ptr[mut ValueList] {
    // Each group's value and items, found by the value; made into records once they're all in
    keys : Value[..]
    defer runtime.array_free(&keys)
    members : ptr[mut ValueList][..]
    defer runtime.array_free(&members)
    for item in items {
        key :: key_of(item, name)
        found := keys.count
        for each, i in keys {
            if found == keys.count && (compare(each, key) or_else 1) == 0 {
                found = i
            }
        }
        // A new value's group is the next, at found
        if found >= keys.count {
            runtime.array_add(&keys, key)
            runtime.array_add(&members, new_list())
        }
        for list, i in members {
            if i == found {
                runtime.array_add(&list.items, item)
            }
        }
    }
    named :: if name == "count" || name == "items" { "key" } else { name }
    made :: new_list()
    for key, i in keys {
        if i >= members.count {
            break
        }
        group :: new_record()
        set_field(group, named, key)
        set_field(group, "count", .Int(cast[i64](members[i].items.count)))
        set_field(group, "items", .List(members[i]))
        runtime.array_add(&made.items, Value.Record(group))
    }
    return made
}
