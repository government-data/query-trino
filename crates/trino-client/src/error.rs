//! Trino's errors as a caller keeps them: the error's name and type, never
//! its message, which may quote a value (decision 0090, point 7.6).

use serde_json::Value;

/// Why a statement gave no answer.
#[derive(Clone, PartialEq, Eq)]
pub enum TrinoError {
    /// Trino could not be reached, or answered what is not its protocol.
    Unavailable(String),
    /// Trino refused the token (401) or the statement (403).
    Refused(u16),
    /// A page's `nextUri` is gone (404): the coordinator restarted.
    Gone,
    /// The statement failed: Trino's error name (`TABLE_NOT_FOUND`), its
    /// type (`USER_ERROR`, `INSUFFICIENT_RESOURCES`, …) and its message.
    /// The message is kept for the caller to drop: it is not displayed, not
    /// debugged and never logged.
    Failed {
        name: String,
        error_type: String,
        message: String,
    },
}

impl TrinoError {
    /// Trino's error object as a [`TrinoError::Failed`].
    pub(crate) fn from_error(error: &Value) -> Self {
        let text = |key: &str| {
            error
                .get(key)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string()
        };
        Self::Failed {
            name: text("errorName"),
            error_type: text("errorType"),
            message: text("message"),
        }
    }

    /// What kind of error it is, as a class: Trino's error name when it
    /// failed (`EXCEEDED_LOCAL_MEMORY_LIMIT`), else `unavailable`,
    /// `refused` or `gone`.
    #[must_use]
    pub fn kind(&self) -> &str {
        match self {
            Self::Unavailable(_) => "unavailable",
            Self::Refused(_) => "refused",
            Self::Gone => "gone",
            Self::Failed { name, .. } => name,
        }
    }
}

impl std::fmt::Display for TrinoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable(why) => write!(f, "trino unavailable: {why}"),
            Self::Refused(code) => write!(f, "trino refused: {code}"),
            Self::Gone => f.write_str("trino: the query is gone"),
            Self::Failed {
                name, error_type, ..
            } => write!(f, "trino: {name} ({error_type})"),
        }
    }
}

impl std::fmt::Debug for TrinoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable(why) => f.debug_tuple("Unavailable").field(why).finish(),
            Self::Refused(code) => f.debug_tuple("Refused").field(code).finish(),
            Self::Gone => f.write_str("Gone"),
            Self::Failed {
                name, error_type, ..
            } => f
                .debug_struct("Failed")
                .field("name", name)
                .field("error_type", error_type)
                .finish_non_exhaustive(),
        }
    }
}

impl std::error::Error for TrinoError {}
