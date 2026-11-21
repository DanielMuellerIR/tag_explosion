use std::path::PathBuf;

// Zweitstartargumente gehören zum Arbeitsverzeichnis des aufrufenden Prozesses.
pub(crate) fn existing_file_arguments(args: Vec<String>, cwd: &str) -> Vec<String> {
    args.into_iter()
        .skip(1)
        .filter(|argument| !argument.is_empty())
        .map(PathBuf::from)
        .map(|path| {
            if path.is_absolute() {
                path
            } else {
                PathBuf::from(cwd).join(path)
            }
        })
        .filter(|path| path.exists())
        .map(|path| path.to_string_lossy().into_owned())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_argument_does_not_become_the_working_directory() {
        let folder = tempfile::tempdir().unwrap();
        let file = folder.path().join("chapter.mp3");
        std::fs::File::create(&file).unwrap();
        assert_eq!(
            existing_file_arguments(
                vec!["tag-explosion".into(), "".into(), "chapter.mp3".into()],
                folder.path().to_str().unwrap()
            ),
            vec![file.to_str().unwrap().to_owned()]
        );
    }
}
