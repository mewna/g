{application,libring,
             [{description,"A fast consistent hash ring implementation in Elixir"},
              {modules,['Elixir.HashRing','Elixir.HashRing.App',
                        'Elixir.HashRing.Managed','Elixir.HashRing.Utils',
                        'Elixir.HashRing.Worker','Elixir.Inspect.HashRing']},
              {registered,[]},
              {vsn,"1.3.1"},
              {applications,[kernel,stdlib,elixir,crypto]},
              {mod,{'Elixir.HashRing.App',[]}}]}.
