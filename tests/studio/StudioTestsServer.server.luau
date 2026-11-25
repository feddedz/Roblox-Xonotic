--!strict
-- Server side of the Studio test place: confirms the Lighting setup the project file applied.
local Lighting = game:GetService("Lighting")
print(
	string.format(
		"[StudioTests] server: Lighting.Technology=%s (must be Future; set by studio-tests.project.json)",
		tostring(Lighting.Technology)
	)
)
