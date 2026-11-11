import SwiftUI

struct KVRow: Equatable, Sendable {
    var name: String
    var value: String
    var disabled: Bool
}

enum KVEdit {
    case set(Int, KVRow)
    case remove(Int)
    case append
    case replaceAll([KVRow])

    func apply<Element>(to array: inout [Element], row: (Element) -> KVRow, make: (KVRow, Element?) -> Element) {
        switch self {
        case .set(let index, let value):
            guard array.indices.contains(index) else { return }
            array[index] = make(value, array[index])
        case .remove(let index):
            guard array.indices.contains(index) else { return }
            array.remove(at: index)
        case .append:
            array.append(make(KVRow(name: "", value: "", disabled: false), nil))
        case .replaceAll(let rows):
            let byName = Dictionary(array.map { (row($0).name, $0) }, uniquingKeysWith: { first, _ in first })
            array = rows.map { make($0, byName[$0.name]) }
        }
    }
}

/// Enable / name / value rows with an optional extra column, used for params,
/// headers, form fields, and variables.
struct KeyValueTable<Extra: View>: View {
    let rows: [KVRow]
    let noun: String
    var namePlaceholder = "Name"
    var valuePlaceholder = "Value"
    var extraTitle: String?
    var extraWidth: CGFloat = 84
    var variables: VariableScope?
    let onEdit: (KVEdit) -> Void
    @ViewBuilder var extra: (Int) -> Extra

    var body: some View {
        FieldTable {
            TableRow(isHeader: true) {
                Color.clear.frame(width: 18, height: 1)
                if let extraTitle {
                    Text(extraTitle)
                        .frame(width: extraWidth, alignment: .leading)
                }
                Text("Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Value")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 18, height: 1)
            }

            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                TableRow {
                    Toggle("", isOn: Binding(
                        get: { !row.disabled },
                        set: { enabled in onEdit(.set(index, KVRow(name: row.name, value: row.value, disabled: !enabled))) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: 18)
                    .accessibilityLabel("Enable \(noun)")

                    if extraTitle != nil {
                        extra(index)
                            .frame(width: extraWidth)
                    }

                    VariableField(
                        namePlaceholder,
                        text: Binding(
                            get: { row.name },
                            set: { name in onEdit(.set(index, KVRow(name: name, value: row.value, disabled: row.disabled))) }
                        ),
                        variables: variables
                    )
                    .accessibilityLabel("\(noun.capitalized) name")

                    VariableField(
                        valuePlaceholder,
                        text: Binding(
                            get: { row.value },
                            set: { value in onEdit(.set(index, KVRow(name: row.name, value: value, disabled: row.disabled))) }
                        ),
                        variables: variables
                    )
                    .accessibilityLabel("\(noun.capitalized) value")

                    RemoveRowButton(label: "Remove \(noun)") {
                        onEdit(.remove(index))
                    }
                }
                .opacity(row.disabled ? 0.5 : 1)
            }

            AddRowButton(label: "Add \(noun)") {
                onEdit(.append)
            }
        }
    }
}

extension KeyValueTable where Extra == EmptyView {
    init(
        rows: [KVRow],
        noun: String,
        namePlaceholder: String = "Name",
        valuePlaceholder: String = "Value",
        variables: VariableScope? = nil,
        onEdit: @escaping (KVEdit) -> Void
    ) {
        self.rows = rows
        self.noun = noun
        self.namePlaceholder = namePlaceholder
        self.valuePlaceholder = valuePlaceholder
        self.variables = variables
        self.onEdit = onEdit
        self.extra = { _ in EmptyView() }
    }
}

extension OCHeader {
    var kvRow: KVRow { KVRow(name: name, value: value, disabled: disabled) }
    init(_ row: KVRow) { self.init(name: row.name, value: row.value, disabled: row.disabled) }
}

extension OCParam {
    var kvRow: KVRow { KVRow(name: name, value: value, disabled: disabled) }
}

extension OCVariable {
    var kvRow: KVRow { KVRow(name: name, value: value, disabled: disabled) }
}

extension Array where Element == OCHeader {
    mutating func apply(_ edit: KVEdit) {
        edit.apply(to: &self, row: \.kvRow) { row, _ in OCHeader(row) }
    }
}

extension Array where Element == OCParam {
    mutating func apply(_ edit: KVEdit) {
        edit.apply(to: &self, row: \.kvRow) { row, existing in
            OCParam(name: row.name, value: row.value, kind: existing?.kind ?? "query", disabled: row.disabled)
        }
    }
}

extension Array where Element == OCVariable {
    mutating func apply(_ edit: KVEdit) {
        edit.apply(to: &self, row: \.kvRow) { row, existing in
            OCVariable(name: row.name, value: row.value, secret: existing?.secret ?? false, disabled: row.disabled)
        }
    }
}
