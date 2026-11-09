use std::path::PathBuf;

// Zweitstartargumente gehören zum Arbeitsverzeichnis des aufrufenden Prozesses.
pub(crate) fn existing_file_arguments(args: Vec<String>, cwd: &str) -> Vec<String> {
    args.into_iter()
        .skip(1)
        .map(PathBuf::from)
        .map(|path| if path.is_absolute() { path } else { PathBuf::from(cwd).join(path) })
        .filter(|path| path.exists())
        .map(|path| path.to_string_lossy().into_owned())
        .collect()
}
