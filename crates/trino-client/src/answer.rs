//! A statement's answer as its pages give it.

use serde_json::Value;

/// A result column: its name and Trino's type (`bigint`, `varchar(3)`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Column {
    pub name: String,
    pub type_name: String,
}

/// What a statement answered.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Answer {
    /// Its query's id, once Trino gave it.
    pub query_id: Option<String>,
    /// `INSERT`, `DELETE`, `CREATE TABLE`, … for a statement that changes
    /// something; none for a query.
    pub update_type: Option<String>,
    /// The rows it changed, when Trino says.
    pub update_count: Option<u64>,
    pub columns: Vec<Column>,
    pub rows: Vec<Vec<Value>>,
}

impl Answer {
    /// Takes what one page adds: columns once, update type and count, rows.
    pub(crate) fn read_page(&mut self, page: &Value) {
        if self.columns.is_empty() {
            if let Some(Value::Array(cols)) = page.get("columns") {
                self.columns = cols
                    .iter()
                    .map(|c| Column {
                        name: text(c, "name"),
                        type_name: text(c, "type"),
                    })
                    .collect();
            }
        }
        if let Some(t) = page.get("updateType").and_then(Value::as_str) {
            self.update_type = Some(t.to_string());
        }
        if let Some(n) = page.get("updateCount").and_then(Value::as_u64) {
            self.update_count = Some(n);
        }
        if let Some(Value::Array(data)) = page.get("data") {
            self.rows
                .extend(data.iter().filter_map(|r| r.as_array().cloned()));
        }
    }
}

fn text(v: &Value, key: &str) -> String {
    v.get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}
