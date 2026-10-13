// The Rust side of bindings/rows.rb's Row record, for test/test_records.rb.

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct Row {
    pub text: String,
    pub href: Option<String>,
    pub rank: i64,
}

pub fn make(count: i64) -> Vec<Row> {
    (0..count)
        .map(|i| Row { text: format!("row{i}"), href: (i == 0).then(|| "https://example.com".to_string()), rank: i })
        .collect()
}
