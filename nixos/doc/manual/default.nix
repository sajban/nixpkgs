{ pkgs
, options
, config
, version
, revision
, extraSources ? [ ]
, baseOptionsJSON ? null
, warningsAreErrors ? true
, prefix ? ../../..
}:

with pkgs;

let
  inherit (lib) hasPrefix removePrefix;

  lib = pkgs.lib;

  manpageUrls = pkgs.path + "/doc/manpage-urls.json";

  # We need to strip references to /nix/store/* from options,
  # including any `extraSources` if some modules came from elsewhere,
  # or else the build will fail.
  #
  # E.g. if some `options` came from modules in ${pkgs.customModules}/nix,
  # you'd need to include `extraSources = [ pkgs.customModules ]`
  prefixesToStrip = map (p: "${toString p}/") ([ prefix ] ++ extraSources);
  stripAnyPrefixes = lib.flip (lib.foldr lib.removePrefix) prefixesToStrip;

  optionsDoc = buildPackages.nixosOptionsDoc {
    inherit options revision baseOptionsJSON warningsAreErrors;
    transformOptions = opt: opt // {
      # Clean up declaration sites to not refer to the NixOS source tree.
      declarations = map stripAnyPrefixes opt.declarations;
    };
  };

  nixos-lib = import ../../lib { featureFlags = {
    # We use a minimal module list to evaluate the docs of the extra modules.
    # This is significantly faster than loading all the modules, and we can pull
    # this off because we don't require any dependencies to be loaded.
    minimalModules = { }; };
  };

  cleanupLocations = opt: opt // {
    # Clean up declaration sites to not refer to the NixOS source tree.
    declarations =
      map
        (decl:
          if hasPrefix (toString ../../..) (toString decl)
          then
            let subpath = removePrefix "/" (removePrefix (toString ../../..) (toString decl));
            in { url = "https://github.com/NixOS/nixpkgs/blob/master/${subpath}"; name = subpath; }
          else decl)
        opt.declarations;
  };

  testOptionsDoc =
    let
      eval = nixos-lib.evalTest {
        # Avoid evaluating a NixOS config prototype.
        config.node.type = lib.types.deferredModule;
        options._module.args = lib.mkOption { internal = true; };
      };
    in
    buildPackages.nixosOptionsDoc {
      inherit (eval) options;
      inherit revision;
      transformOptions = cleanupLocations;
      documentType = "none";
      variablelistId = "test-options-list";
      optionIdPrefix = "test-opt-";
    };

  toc = builtins.toFile "toc.xml"
    ''
      <toc role="chunk-toc">
        <d:tocentry xmlns:d="http://docbook.org/ns/docbook" linkend="book-nixos-manual"><?dbhtml filename="index.html"?>
          <d:tocentry linkend="ch-options"><?dbhtml filename="options.html"?></d:tocentry>
          <d:tocentry linkend="ch-release-notes"><?dbhtml filename="release-notes.html"?></d:tocentry>
        </d:tocentry>
      </toc>
    '';

  manualXsltprocOptions = toString [
    "--param chapter.autolabel 0"
    "--param part.autolabel 0"
    "--param preface.autolabel 0"
    "--param reference.autolabel 0"
    "--param section.autolabel 0"
    "--stringparam html.stylesheet 'style.css overrides.css highlightjs/mono-blue.css'"
    "--stringparam html.script './highlightjs/highlight.pack.js ./highlightjs/loader.js'"
    "--param xref.with.number.and.title 0"
    "--param toc.section.depth 0"
    "--param generate.consistent.ids 1"
    "--stringparam admon.style ''"
    "--stringparam callout.graphics.extension .svg"
    "--stringparam current.docid manual"
    "--param chunk.section.depth 0"
    "--param chunk.first.sections 1"
    "--param use.id.as.filename 1"
    "--stringparam chunk.toc ${toc}"
  ];

  linterFunctions = ''
    # outputs the context of an xmllint error output
    # LEN lines around the failing line are printed
    function context {
      # length of context
      local LEN=6
      # lines to print before error line
      local BEFORE=4

      # xmllint output lines are:
      # file.xml:1234: there was an error on line 1234
      while IFS=':' read -r file line rest; do
        echo
        if [[ -n "$rest" ]]; then
          echo "$file:$line:$rest"
          local FROM=$(($line>$BEFORE ? $line - $BEFORE : 1))
          # number lines & filter context
          nl --body-numbering=a "$file" | sed -n "$FROM,+$LEN p"
        else
          if [[ -n "$line" ]]; then
            echo "$file:$line"
          else
            echo "$file"
          fi
        fi
      done
    }

    function lintrng {
      xmllint --debug --noout --nonet \
        --relaxng ${docbook5}/xml/rng/docbook/docbook.rng \
        "$1" \
        2>&1 | context 1>&2
        # ^ redirect assumes xmllint doesn’t print to stdout
    }
  '';

  optionalDocs = lib.mapAttrs
    (name: module:
      let
        # This is quite simple for now, but may need stubs for more complex modules.
        eval = nixos-lib.evalModules {
          modules = [
            module
            { options._module.args = lib.mkOption { internal = true; }; }
          ];
        };
      in
      buildPackages.nixosOptionsDoc {
        inherit (eval) options;
        inherit revision;
        transformOptions = cleanupLocations;
        # These are for direct to docbook generation, which we don't use here.
        documentType = throw "documentType not set";
        variablelistId = throw "variablelistId not set";
        optionIdPrefix = throw "optionIdPrefix not set";
      }
  ) {
    # NOTE: These don't have to be paths. If a module needs dependencies to be loaded
    #       for doc rendering, do something like
    #           newModule = { imports = [ ../../modules/new.nix ../../modules/dep.nix ]; }
    #       or import it transitively.
    readOnlyPkgs = ../../modules/misc/nixpkgs/read-only.nix;
    noLegacyPkgs = ../../modules/misc/nixpkgs/no-legacy.nix;
  };

  prepareManualFromMD = ''
    cp -r --no-preserve=all $inputs/* .

    substituteInPlace ./manual.md \
      --replace '@NIXOS_VERSION@' "${version}"
    substituteInPlace ./configuration/configuration.md \
      --replace \
          '@MODULE_CHAPTERS@' \
          ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (p: "${p.value}") config.meta.doc)}
    substituteInPlace ./nixos-options.md \
      --replace \
        '@NIXOS_OPTIONS_JSON@' \
        ${optionsDoc.optionsJSON}/share/doc/nixos/options.json
    substituteInPlace ./nixos-optional-modules.md \
      --replace \
        '@OPTIONS_JSON_noLegacyPkgs@' \
        ${optionalDocs.noLegacyPkgs.optionsJSON}/share/doc/nixos/options.json \
      --replace \
        '@OPTIONS_JSON_readOnlyPkgs@' \
        ${optionalDocs.readOnlyPkgs.optionsJSON}/share/doc/nixos/options.json \
        ;
    substituteInPlace ./development/writing-nixos-tests.section.md \
      --replace \
        '@NIXOS_TEST_OPTIONS_JSON@' \
        ${testOptionsDoc.optionsJSON}/share/doc/nixos/options.json
  '';

in
rec {
  inherit (optionsDoc) optionsJSON optionsNix optionsDocBook;

  # Generate the NixOS manual.
  manualHTML = runCommand "nixos-manual-html"
    {
      nativeBuildInputs = [ buildPackages.nixos-render-docs ];
      inputs = lib.sourceFilesBySuffices ./. [ ".md" ];
      meta.description = "The NixOS manual in HTML format";
      allowedReferences = [ "out" ];
    }
    ''
      # Generate the HTML manual.
      dst=$out/share/doc/nixos
      mkdir -p $dst

      cp ${../../../doc/style.css} $dst/style.css
      cp ${../../../doc/overrides.css} $dst/overrides.css
      cp -r ${pkgs.documentation-highlighter} $dst/highlightjs

      ${prepareManualFromMD}

      nixos-render-docs -j $NIX_BUILD_CORES manual html \
        --manpage-urls ${manpageUrls} \
        --revision ${lib.escapeShellArg revision} \
        --generator "nixos-render-docs ${lib.version}" \
        --stylesheet style.css \
        --stylesheet overrides.css \
        --stylesheet highlightjs/mono-blue.css \
        --script ./highlightjs/highlight.pack.js \
        --script ./highlightjs/loader.js \
        --toc-depth 1 \
        --chunk-toc-depth 1 \
        ./manual.md \
        $dst/index.html

      mkdir -p $out/nix-support
      echo "nix-build out $out" >> $out/nix-support/hydra-build-products
      echo "doc manual $dst" >> $out/nix-support/hydra-build-products
    ''; # */

  # Alias for backward compatibility. TODO(@oxij): remove eventually.
  manual = manualHTML;

  # Index page of the NixOS manual.
  manualHTMLIndex = "${manualHTML}/share/doc/nixos/index.html";

  manualEpub = runCommand "nixos-manual-epub"
    {
      nativeBuildInputs = [ buildPackages.libxml2.bin buildPackages.libxslt.bin buildPackages.zip ];
      doc = ''
        <book xmlns="http://docbook.org/ns/docbook"
              xmlns:xlink="http://www.w3.org/1999/xlink"
              version="5.0"
              xml:id="book-nixos-manual">
          <info>
            <title>NixOS Manual</title>
            <subtitle>Version ${lib.version}</subtitle>
          </info>
          <chapter>
            <title>Temporarily unavailable</title>
            <para>
              The NixOS manual is currently not available in EPUB format,
              please use the <link xlink:href="https://nixos.org/nixos/manual">HTML manual</link>
              instead.
            </para>
            <para>
              If you've used the EPUB manual in the past and it has been useful to you, please
              <link xlink:href="https://github.com/NixOS/nixpkgs/issues/237234">let us know</link>.
            </para>
          </chapter>
        </book>
      '';
      passAsFile = [ "doc" ];
    }
    ''
      # Generate the epub manual.
      dst=$out/share/doc/nixos

      xsltproc \
        --param chapter.autolabel 0 \
        --nonet --xinclude --output $dst/epub/ \
        ${docbook_xsl_ns}/xml/xsl/docbook/epub/docbook.xsl \
        $docPath

      echo "application/epub+zip" > mimetype
      manual="$dst/nixos-manual.epub"
      zip -0Xq "$manual" mimetype
      cd $dst/epub && zip -Xr9D "$manual" *

      rm -rf $dst/epub

      mkdir -p $out/nix-support
      echo "doc-epub manual $manual" >> $out/nix-support/hydra-build-products
    '';


  # Generate the NixOS manpages.
  manpages = runCommand "nixos-manpages"
    {
      nativeBuildInputs = [
        buildPackages.installShellFiles
        buildPackages.nixos-render-docs
      ];
      allowedReferences = [ "out" ];
    }
    ''
      # Generate manpages.
      mkdir -p $out/share/man/man8
      installManPage ${./manpages}/*
      mkdir -p $out/share/man/man5
      nixos-render-docs -j $NIX_BUILD_CORES options manpage \
        --revision ${lib.escapeShellArg revision} \
        ${optionsJSON}/share/doc/nixos/options.json \
        $out/share/man/man5/configuration.nix.5
    '';

}
