{ lib
, buildPythonPackage
, pythonOlder
, fetchPypi
, setuptoolsBuildHook
, attrs
, cattrs
, toml
, pytestCheckHook
, click
}:

buildPythonPackage rec {
  pname = "typed-settings";
  version = "1.0.0";
  format = "pyproject";
  disabled = pythonOlder "3.7";

  src = fetchPypi {
    inherit pname version;
    sha256 = "sha256-c+iOb1F8+9IoRbwpMTdyDfOPW2ZEo4xDAlbzLAxgSfk=";
  };

  nativeBuildInputs = [
    setuptoolsBuildHook
  ];

  propagatedBuildInputs = [
    attrs
    cattrs
    toml
  ];

  preCheck = ''
    pushd tests
  '';

  checkInputs = [
    click
    pytestCheckHook
  ];

  disabledTests = [
    # mismatches in click help output
    "test_help"
  ];

  postCheck = ''
    popd
  '';

  meta = {
    description = "Typed settings based on attrs classes";
    homepage = "https://gitlab.com/sscherfke/typed-settings";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ fridh ];
  };
}
