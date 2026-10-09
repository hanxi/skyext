local patcher = {}
patcher.targets = { ".gm" }

-- patch执行的代码
function patcher.run()
    print("run hotfix patch in code2.")
    return true
end

return patcher
