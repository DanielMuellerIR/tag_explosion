"""Isolierter Rust-Verhaltenstest ohne Tauri/GUI oder Produktbau."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]

class SingleInstanceTests(unittest.TestCase):
    def test_paths_use_invoking_process_directory(self):
        source = (ROOT / 'Linux/src/file_args.rs').read_text()
        tests = r'''
#[test]
fn invocation_directory() {
    let root = std::env::current_dir().unwrap().join("own-fixtures");
    std::fs::create_dir_all(root.join("second")).unwrap();
    let file = root.join("second/song.mp3");
    std::fs::write(&file, b"own meaningless fixture").unwrap();
    let args = vec!["app".into(), "song.mp3".into(), "missing.mp3".into()];
    assert_eq!(existing_file_arguments(args, root.join("second").to_str().unwrap()), vec![file.to_string_lossy().to_string()]);
    assert_eq!(existing_file_arguments(vec!["app".into(), file.to_string_lossy().to_string()], "/unused"), vec![file.to_string_lossy().to_string()]);
    std::fs::remove_dir_all(root).unwrap();
}
'''
        with tempfile.TemporaryDirectory(prefix='tagx-rust-paths-') as temp:
            path = pathlib.Path(temp)
            (path / 'test.rs').write_text(source + tests)
            compiled = subprocess.run(['rustc', '--edition=2021', '--test', str(path/'test.rs'), '-o', str(path/'test')], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(path/'test')], cwd=temp, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

if __name__ == '__main__':
    unittest.main()
