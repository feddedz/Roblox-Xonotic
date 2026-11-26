// general keywords
textures/tv/sp_all
{
	surfaceparm alphashadow
	surfaceparm areaportal
	surfaceparm botclip
	surfaceparm clusterportal
	surfaceparm detail
	surfaceparm donotenter
	surfaceparm dust
	surfaceparm hint
	surfaceparm fog
	surfaceparm lava
	surfaceparm lightfilter
	surfaceparm lightgrid
	surfaceparm metalsteps
	surfaceparm nodamage
	surfaceparm nodlight
	surfaceparm nodraw
	surfaceparm nodrop
	surfaceparm noimpact
	surfaceparm nolightmap
	surfaceparm nomarks
	surfaceparm nomipmaps
	surfaceparm nonsolid
	surfaceparm origin
	surfaceparm playerclip
	surfaceparm sky
	surfaceparm slick
	surfaceparm slime
	surfaceparm structural
	surfaceparm trans
	surfaceparm water
	surfaceparm pointlight
	surfaceparm antiportal
	surfaceparm skip
	surfaceparm bogusparm
	surfaceparm dp_water
	surfaceparm tvcontent
	surfaceparm
	{
		map textures/tv/sp_all.tga
	}
}

textures/tv/sp_custom
{
	surfaceparm TVFLAG1
	surfaceparm tvflag2
	surfaceparm tvoct
	surfaceparm tvdup
	surfaceparm tvlast
	surfaceparm tvx
	surfaceparm NoDraw
	{
		map textures/tv/sp_custom.tga
	}
}

textures/tv/sp_neg
{
	surfaceparm tvneg
}

textures/tv/sp_big
{
	surfaceparm tvbig
}

textures/tv/sp_negbig
{
	surfaceparm tvnegbig
}

textures/tv/sp_huge
{
	surfaceparm tvhuge
}

textures/tv/sp_prec
{
	surfaceparm tvprec
}

textures/tv/sp_lava
{
	surfaceparm lava
	surfaceparm nodrop
	{
		map textures/tv/lava.tga
	}
}

textures/tv/sp_slime
{
	surfaceparm slime
	surfaceparm playerclip
	{
		map textures/tv/slime.tga
	}
}

textures/tv/sp_water
{
	surfaceparm water
	surfaceparm nonsolid
	surfaceparm trans
	surfaceparm alphashadow
	surfaceparm lightfilter
	surfaceparm metalsteps
	surfaceparm nodamage
	surfaceparm nodlight
	surfaceparm noimpact
	surfaceparm nomarks
	surfaceparm pointlight
	surfaceparm hint
	surfaceparm dust
	surfaceparm slick
	{
		map textures/tv/water.tga
		blendfunc blend
	}
}

textures/tv/sp_botclip
{
	surfaceparm botclip
	surfaceparm donotenter
	surfaceparm nolightmap
}

textures/tv/sp_nodraw
{
	surfaceparm nodraw
}

textures/tv/general
{
	{
		map textures/tv/before.tga
		blendfunc GL_ONE GL_ONE
	}
	dp_shadow
	DP_NOSHADOW
	dpnortlight
	dpmeshcollisions
	dpcamera
	dp_reflectcube env/cube
	cull none
	nomipmaps
	nopicmip
	polygonoffset
	dptransparentsort hud
	dpglossintensitymod 2.5
	dpglossexponentmod 0.1
	dprtlightambient 0.25
	dpoffsetmapping linear 0.5 bias 0.25
	q3map_lightimage textures/tv/light.tga
	{
		map textures/tv/after.tga
		clampmap textures/tv/after2.tga
		alphafunc GT0
	}
}

textures/tv/water
{
	dprefract 0.5 1 0.5 0.25
	dpreflect 2 0.1 0.2 0.3 0.4
	dpcamera
	dpwater 0.1 0.9 1.5 1.2 0.5 0.6 0.7 0.8 0.9 1.0 0.75
	dpwaterscroll 4 0
	{
		map textures/tv/water.tga
	}
}

textures/tv/refract
{
	dpwater 0.1 0.9 1.5 1.2 0.5 0.6 0.7 0.8 0.9 1.0
	dprefract 0.5 1 0.5
	dpreflect 2 0.1 0.2 0.3
	dprefract 1.25 0.3 0.6 0.9 7
	dpreflect 0.75 1 0.5 0.25 0.125
	dpwaterscroll 3
	dpglossintensitymod
	dpglossexponentmod
	dprtlightambient
}

textures/tv/scroll
{
	dpwaterscroll -8 0.3
	dpglossintensitymod nan
	dpglossexponentmod -inf
	dprtlightambient 0x10
}

textures/tv/reflectcube_stale
{
	dprtlightambient env/stale
	dpreflectcube
}

textures/tv/sky
{
	sky env/tvsky
}

textures/tv/skyparms
{
	skyparms env/tvbox 512 -
}

textures/tv/skyparms_dash
{
	skyparms - 512 -
}

textures/tv/skyparms_num
{
	skyparms 512 - -
}

textures/tv/skyparms_zero
{
	skyparms 0 - -
	{
		map textures/tv/sky.tga
	}
}

textures/tv/sky_alone
{
	sky
	skyparms
}

textures/tv/cull_disable
{
	cull disable
	{
		map textures/tv/c.tga
	}
}

textures/tv/cull_twosided
{
	cull back
	cull TwoSided
}

textures/tv/cull_back
{
	cull back
	cull
}

textures/tv/polyoff1
{
	dppolygonoffset
}

textures/tv/polyoff2
{
	dppolygonoffset 2
}

textures/tv/polyoff3
{
	dppolygonoffset 1.5 -3
	{
		map textures/tv/p.tga
	}
}

textures/tv/tsort_sky
{
	dptransparentsort sky
}

textures/tv/tsort_distance
{
	dptransparentsort hud
	dptransparentsort distance
}

textures/tv/tsort_bogus
{
	dptransparentsort bogus
	dptransparentsort
}

textures/tv/om_off
{
	dpoffsetmapping disable
}

textures/tv/om_none
{
	dpoffsetmapping none 2
}

textures/tv/om_off2
{
	dpoffsetmapping OFF
}

textures/tv/om_default
{
	dpoffsetmapping default 0.5 match 0.25
}

textures/tv/om_normal
{
	dpoffsetmapping normal 1 match8 128
}

textures/tv/om_relief
{
	dpoffsetmapping relief 2 match16 32768
}

textures/tv/om_bogus
{
	dpoffsetmapping bogus 3 bogusmode 1
}

textures/tv/om_four
{
	dpoffsetmapping linear 1 bias
	dpoffsetmapping
}

textures/tv/deform1
{
	deformvertexes wave 100 sin 0 1 0.5 2 9
	deformvertexes move 1 2 3 triangle 0 4 0 0.5
	deformvertexes autosprite
	deformvertexes bulge 1 2 3 4
	deformvertexes normal 0.1 2
}

textures/tv/deform2
{
	deformvertexes bogus 1 2 3
	deformvertexes autosprite2
	deformvertexes projectionshadow
	deformvertexes text0
	deformvertexes text1
	deformvertexes text2
}

textures/tv/deform3
{
	deformvertexes
	dpwater a b user4noise d sawtooth
	deformvertexes wave
	deformvertexes move
	deformVertexes Text3 7
}

textures/tv/deform4
{
	deformvertexes text4
	deformvertexes text5
	deformvertexes text6
	deformvertexes text7
}
