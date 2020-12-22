The model converter leverages a 3rd party model importing library called "ASSIMP" (Asset Import Library).  Due to an open source licensing concern, ASSIMP is not included in this GitHub repository.  You will need to download ASSIMP and install it to the 3rdParty folder.  The ModelConverter project file will look for ASSIMP in "../3rdParty/assimp-3.0" unless you change the additional include directories.  You may need to rename some files/folders to make the Visual Studio project compile.  It references ASSIMP as follows:

* Include Path: ../3rdParty/assimp-3.0/include
* Library Path: ../3rdParty/assimp-3.0/lib/release
* Post-build: ../3rdParty/assimp-3.0/bin/release/assimp.dll

You should also have "assimp.dll" in your path.  We recommended copying this DLL to the ModelConverter folder.  The most recent version of ASSIMP is 3.2, but we have only tested with 3.0.  You are welcome to make the necessary (if any) changes to work with 3.2.  Please notify us via pull request or forum post if you find some discrepencies.

Regards,
Team Minigraph