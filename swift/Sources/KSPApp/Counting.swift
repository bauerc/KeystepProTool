/// Pluralised by the count, for the several views that say "3 notes" or "1 bar".
func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}
