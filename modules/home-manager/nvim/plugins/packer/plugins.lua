function myplugins(use)
	 -- Packer can manage itself
	 use 'wbthomason/packer.nvim'
	 
	 -- Themes
	 use 'ishan9299/modus-theme-vim'
	 
	 -- Others
end
	 
return require('packer').startup(myplugins)
