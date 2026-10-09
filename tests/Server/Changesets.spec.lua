--[[
    Pure unit tests for changeset application; no dashboard interaction required.
    The Gamebeast SDK must be running so internal modules are loaded.

    Semantics mirror the backend's changesetMerge: "add" is "set", paths only
    traverse dictionaries, and missing intermediates are never created.
]]

return function()
    local Changesets = shared.GBMod("Changesets")

    local function changeset(operations)
        return { operations = operations }
    end

    describe("Changesets", function()
        it("should return the base document untouched when there are no changesets", function()
            local base = { a = 1 }
            local result = Changesets.apply(base, {})
            expect(result).to.equal(base)
        end)

        it("should never mutate the base document", function()
            local base = { a = { b = 1 } }
            Changesets.apply(base, {
                changeset({ { op = "set", path = { "a", "b" }, value = 2 } }),
            })
            expect(base.a.b).to.equal(1)
        end)

        it("should set values at nested paths", function()
            local result = Changesets.apply({ a = { b = 1 }, c = 2 }, {
                changeset({ { op = "set", path = { "a", "b" }, value = 5 } }),
            })
            expect(result.a.b).to.equal(5)
            expect(result.c).to.equal(2)
        end)

        it("should treat add exactly like set", function()
            local result = Changesets.apply({ a = { existing = 1 } }, {
                changeset({ { op = "add", path = { "a", "b" }, value = 2 } }),
            })
            expect(result.a.b).to.equal(2)
            expect(result.a.existing).to.equal(1)
        end)

        it("should not create missing intermediate tables", function()
            local result = Changesets.apply({ a = 1 }, {
                changeset({ { op = "set", path = { "x", "y", "z" }, value = true } }),
            })
            expect(result.x).never.to.be.ok()
            expect(result.a).to.equal(1)
        end)

        it("should not traverse arrays", function()
            local result = Changesets.apply({ list = { "a", "b" } }, {
                changeset({ { op = "set", path = { "list", "1" }, value = "z" } }),
            })
            expect(result.list[1]).to.equal("a")
            expect(result.list[2]).to.equal("b")
        end)

        it("should delete dictionary keys", function()
            local result = Changesets.apply({ a = 1, b = 2 }, {
                changeset({ { op = "delete", path = { "a" } } }),
            })
            expect(result.a).never.to.be.ok()
            expect(result.b).to.equal(2)
        end)

        it("should no-op deleting a missing path", function()
            local result = Changesets.apply({ a = 1 }, {
                changeset({ { op = "delete", path = { "x", "y" } } }),
            })
            expect(result.a).to.equal(1)
            expect(result.x).never.to.be.ok()
        end)

        it("should apply multiple changesets in order", function()
            local result = Changesets.apply({ value = 0 }, {
                changeset({ { op = "set", path = { "value" }, value = 1 } }),
                changeset({ { op = "set", path = { "value" }, value = 2 } }),
            })
            expect(result.value).to.equal(2)
        end)

        it("should apply operations within a changeset in order", function()
            local result = Changesets.apply({ a = { b = 1 } }, {
                changeset({
                    { op = "set", path = { "a", "c" }, value = 2 },
                    { op = "delete", path = { "a", "b" } },
                }),
            })
            expect(result.a.c).to.equal(2)
            expect(result.a.b).never.to.be.ok()
        end)

        -- The applied value used to be stored by reference, so the second operation wrote into
        -- the cached changeset, and once the composed view was frozen the next apply errored
        it("should not change a changeset when a later operation writes inside a value it set", function()
            local shop = { price = 10 }
            local cached = changeset({
                { op = "set", path = { "shop" }, value = shop },
                { op = "set", path = { "shop", "price" }, value = 5 },
            })

            local first = Changesets.apply({}, { cached })
            expect(first.shop.price).to.equal(5)
            expect(shop.price).to.equal(10)

            -- ApplyConfigs freezes every composed view
            table.freeze(first.shop)

            local second = Changesets.apply({}, { cached })
            expect(second.shop.price).to.equal(5)
        end)
    end)
end
