// dpshaderkillifcvar* / dpnoshaderkillifcvar*, and redeclarations
// cvars (set by the generator and the test): tv_zero 0, tv_one 1, tv_tenth 0.1, tv_neg -2.5, tv_str abc
textures/tv/kill_zero
{
	dpshaderkillifcvarzero tv_zero
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_zero_missing
{
	dpshaderkillifcvarzero tv_missing
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_zero_no
{
	dpshaderkillifcvarzero tv_one
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_zero_str
{
	dpshaderkillifcvarzero tv_str
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_zero_noparm
{
	dpshaderkillifcvarzero
	dpshaderkillifcvar
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_nozero
{
	dpshaderkillifcvarzero tv_zero
	dpnoshaderkillifcvarzero tv_zero
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_nozero2
{
	dp_shaderkillifcvarzero tv_zero
	dpnoshaderkillifcvarzero tv_one
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_plain
{
	dpshaderkillifcvar tv_one
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_plain_no
{
	dpshaderkillifcvar tv_zero
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_eq
{
	dpshaderkillifcvar tv_tenth == 0.1
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_eq2
{
	dpshaderkillifcvar tv_one == 1
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_ne
{
	dpshaderkillifcvar tv_tenth != 0.1
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_gt
{
	dpshaderkillifcvar tv_tenth > 0.1
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_lt
{
	dpshaderkillifcvar tv_neg < -2.5
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_lt2
{
	dpshaderkillifcvar tv_neg < 0
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_ge
{
	dpshaderkillifcvar tv_one >= 1
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_le
{
	dpshaderkillifcvar tv_zero <= -1
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_le2
{
	dpshaderkillifcvar tv_neg <= -2.5
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_badop
{
	dpshaderkillifcvar tv_one = 1
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_noval
{
	dpshaderkillifcvar tv_one ==
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_un
{
	dpshaderkillifcvar tv_one
	dpnoshaderkillifcvar tv_one
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_un_op
{
	dp_shaderkillifcvar tv_one > 0
	dp_noshaderkillifcvar tv_one < 0
	{
		map textures/tv/k.tga
	}
}

textures/tv/kill_case
{
	DPShaderKillIfCvar tv_one
	{
		map textures/tv/k.tga
	}
}

// a killed shader keeps its parsed layers: the texture still reads layers[0].alphatest
textures/tv/kill_alpha
{
	{
		map textures/tv/k.tga
		alphafunc GT0
		blendfunc blend
	}
	{
		map $lightmap
	}
	dpshaderkillifcvar tv_one
	sky env/killed
}

// redeclarations
textures/tv/redecl_same
{
	surfaceparm nodraw
}

textures/tv/redecl_same
{
	surfaceparm nodraw
}

textures/tv/redecl_diff
{
	surfaceparm nodraw
}

textures/tv/redecl_diff
{
	surfaceparm water
}

textures/tv/Redecl_Case
{
	surfaceparm slime
}

textures/tv/redecl_case
{
	surfaceparm lava
}

textures/tv/redecl_killed_then_normal
{
	dpshaderkillifcvar tv_one
	surfaceparm nodraw
}

TEXTURES/TV/REDECL_KILLED_THEN_NORMAL
{
	surfaceparm water
	{
		map textures/tv/r.tga
	}
}

textures/tv/redecl_normal_then_killed
{
	surfaceparm lava
}

textures/tv/redecl_normal_then_killed
{
	dpshaderkillifcvar tv_one
	surfaceparm water
}

textures/tv/redecl_killed_twice
{
	dpshaderkillifcvar tv_one
	surfaceparm slime
}

textures/tv/redecl_killed_twice
{
	dpshaderkillifcvar tv_one
	surfaceparm water
}

// bucket 500: chain828 (killed), chain989, then (e_tokens) chain1233 and chain828 again
textures/tv/chain828
{
	dpshaderkillifcvar tv_one
	surfaceparm nodraw
}

textures/tv/chain989
{
	surfaceparm slick
}

// names longer than 63 characters are cut to 63: these two are the same shader
textures/tv/long_0123456789012345678901234567890123456789012345678901234567890_first
{
	surfaceparm nodraw
}

textures/tv/long_0123456789012345678901234567890123456789012345678901234567890_second
{
	surfaceparm water
}
