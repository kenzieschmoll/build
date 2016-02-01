// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

/// A graph of the package dependencies for an application.
class PackageGraph {
  /// The root application package.
  final PackageNode root;

  /// All [PackageNodes] indexed by package name.
  final Map<String, PackageNode> allPackages;

  PackageGraph._(this.root, Map<String, PackageNode> allPackages)
      : allPackages = new Map.unmodifiable(allPackages);

  /// Creates a [PackageGraph] for the package whose top level directory lives
  /// at [packagePath] (no trailing slash).
  factory PackageGraph.forPath(String packagePath) {
    /// Read in the pubspec file and parse it as yaml.
    var pubspec = new File(path.join(packagePath, 'pubspec.yaml'));
    if (!pubspec.existsSync()) {
      throw 'Unable to generate package graph, no `pubspec.yaml` found. '
          'This program must be ran from the root directory of your package.';
    }
    var rootYaml = loadYaml(pubspec.readAsStringSync());

    /// Read in the `.packages` file to get the locations of all packages.
    var packagesFile = new File(path.join(packagePath, '.packages'));
    if (!packagesFile.existsSync()) {
      throw 'Unable to generate package graph, no `.packages` found. '
          'This program must be ran from the root directory of your package.';
    }
    var packageLocations = <String, Uri>{};
    packagesFile.readAsLinesSync().skip(1).forEach((line) {
      var firstColon = line.indexOf(':');
      var name = line.substring(0, firstColon);
      assert(line.endsWith('lib${Platform.pathSeparator}'));
      // Start after package_name:, and strip out trailing `lib` dir.
      var uriString = line.substring(firstColon + 1, line.length - 4);
      var uri;
      try {
        uri = Uri.parse(uriString);
      } on FormatException catch (_) {
        /// Some types of deps don't have a scheme, and just point to a relative
        /// path.
        uri = new Uri.file(uriString);
      }
      if (!uri.isAbsolute) {
        uri = new Uri.file(path.join(packagePath, uri.path));
      }
      packageLocations[name] = uri;
    });

    /// Create all [PackageNode]s for all deps.
    var nodes = <String, PackageNode>{};
    Map<String, dynamic> rootDeps;
    PackageNode addNodeAndDeps(YamlMap yaml, PackageDependencyType type,
        {bool isRoot: false}) {
      var name = yaml['name'];
      assert(!nodes.containsKey(name));
      var node = new PackageNode._(
          name, yaml['version'], type, packageLocations[name]);
      nodes[name] = node;

      var deps = _depsFromYaml(yaml, withOverrides: isRoot);
      if (isRoot) rootDeps = deps;
      deps.forEach((name, source) {
        var dep = nodes[name];
        if (dep == null) {
          var pubspec = _pubspecForUri(packageLocations[name]);
          dep = addNodeAndDeps(pubspec, _dependencyType(rootDeps[name]));
        }
        node._dependencies.add(dep);
      });

      return node;
    }

    var root =
        addNodeAndDeps(rootYaml, PackageDependencyType.Path, isRoot: true);
    return new PackageGraph._(root, nodes);
  }

  /// Creates a [PackageGraph] for the package in which you are currently
  /// running.
  factory PackageGraph.forThisPackage() => new PackageGraph.forPath('.');

  /// Shorthand to get a package by name.
  PackageNode operator [](String packageName) => allPackages[packageName];

  String toString() {
    var buffer = new StringBuffer();
    for (var package in allPackages.values) {
      buffer.writeln('$package');
    }
    return buffer.toString();
  }
}

/// A node in a [PackageGraph].
class PackageNode {
  /// The name of the package as listed in the pubspec.yaml
  final String name;

  /// The version of the package as listed in the pubspec.yaml
  final String version;

  /// The type of dependency being used to pull in this package.
  final PackageDependencyType dependencyType;

  /// All the packages that this package directly depends on.
  final List<PackageNode> _dependencies = [];
  Iterable<PackageNode> get dependencies => _dependencies.toList();

  /// The location of the current version of this package.
  final Uri location;

  PackageNode._(this.name, this.version, this.dependencyType, this.location);

  String toString() => '''
  $name:
    version: $version
    type: $dependencyType
    location: $location
    dependencies: [${dependencies.map((d) => d.name).join(', ')}]''';
}

/// The type of dependency being used. This dictates how the package should be
/// watched for changes.
enum PackageDependencyType { Pub, Github, Path, }

PackageDependencyType _dependencyType(source) {
  if (source is String || source == null) return PackageDependencyType.Pub;

  assert(source is YamlMap);
  assert(source.keys.length == 1);

  var typeString = source.keys.first;
  switch (typeString) {
    case 'git':
      return PackageDependencyType.Github;
    case 'path':
      return PackageDependencyType.Path;
    default:
      throw 'Unrecognized package dependency type `$typeString`';
  }
}

/// Gets the deps from a yaml file, taking into account dependency_overrides.
Map<String, YamlMap> _depsFromYaml(YamlMap yaml, {bool withOverrides: false}) {
  var deps = new Map.from(yaml['dependencies'] as YamlMap ?? {});
  if (withOverrides) {
    yaml['dependency_overrides']?.forEach((dep, source) {
      deps[dep] = source;
    });
  }
  return deps;
}

/// [uri] should point to the top level directory for the package.
YamlMap _pubspecForUri(Uri uri) {
  var pubspecPath = path.join(uri.toFilePath(), 'pubspec.yaml');
  var pubspec = new File(pubspecPath);
  if (!pubspec.existsSync()) {
    throw 'Unable to generate package graph, no `$pubspecPath` found.';
  }
  return loadYaml(pubspec.readAsStringSync());
}
