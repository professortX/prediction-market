## Motivation
Consider a scenario where the top 2 users who make the largest 2 single order on the prediction markets will win a reward during a promotional period of 2 weeks.

An event listener will pick up the events and filter out the top 2 users. 

The event listener will then check the order size. 

At the end of the 2 weeks, the event listener will calculate the reward for the top 2 users based on the order size.

The proof of the 2 winners will be created and stored on Brevis for transparency.

The prediction markets smart contract will then call Brevis to verify the winners and distribute the rewards.

This helps to ensure that computing the winners of the promotional event is gas efficient and has a way to verify them.


## Testing of circuit
1. Install `Go` from [official documentation](https://go.dev/doc/install)
2. Run `go test`