fn language_code(locale: &str) -> Option<&'static str> {
    let tag = locale.trim().split(['_', '-', '.', '@']).next()?;
    if tag.eq_ignore_ascii_case("de") {
        Some("de")
    } else if tag.eq_ignore_ascii_case("en") {
        Some("en")
    } else {
        None
    }
}

pub fn language() -> &'static str {
    if let Ok(preferred) = std::env::var("LANGUAGE") {
        if let Some(language) = preferred.split(':').find_map(language_code) {
            return language;
        }
    }
    ["LC_ALL", "LC_MESSAGES", "LANG"]
        .iter()
        .filter_map(|key| std::env::var(key).ok())
        .find(|locale| !locale.trim().is_empty())
        .as_deref()
        .and_then(language_code)
        .unwrap_or("en")
}

pub fn text(german: &'static str, english: &'static str) -> &'static str {
    if language() == "de" {
        german
    } else {
        english
    }
}
