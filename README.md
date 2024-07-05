# UnityDocfxXrefMaps

Generates XRef maps from the Unity source reference for use with DocFX.

An index of all maps can be found at <https://rageagainstthepixel.github.io/UnityDocfxXrefMaps>

The URL for a map follows the pattern:

`rageagainstthepixel.github.io/UnityDocfxXrefMaps/<year>.<major>/xrefmap.yml`

The available versions are generated from each of the branches of [Unity's C# Reference repository](https://github.com/Unity-Technologies/UnityCsReference).

Special Thanks to [@nicoco007](https://github.com/nicoco007/UnityXRefMap) and [@NormandErwan](https://github.com/NormandErwan/UnityXrefMaps) for whom most of this implementation is based on.

## Reference Unity XRefMap in your docfx builds

```json
"build": {
    "xref": [
+        "https://rageagainstthepixel.github.io/UnityXrefMaps/<year>.<major>/xrefmap.yml"
    ]
}
```

## Third Party Notices

This repository is not sponsored by or affiliated with Unity Technologies or its affiliates. “Unity” is a trademark or registered trademark of Unity Technologies or its affiliates in the U.S. and elsewhere.
